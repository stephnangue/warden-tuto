#!/usr/bin/env bash
#
# Brings up OpenBao, Keycloak and Warden, and wires the delegation path between
# them. Idempotent — safe to re-run.
#
#   ./up.sh
#   ./enroll.py alice      # one-time GitHub consent, per user
#   ./mcp-config.sh alice  # prints the .mcp.json block for Claude Code
#
# Requires docker compose, curl, python3, and a GitHub OAuth App
# (GH_CLIENT_ID / GH_CLIENT_SECRET — see .env.example).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Sourced before anything else: it can override the host ports below.
if [ -f .env ]; then set -a; . ./.env; set +a; fi

BAO_ADDR="http://127.0.0.1:${BAO_PORT:-8200}"
BAO_TOKEN="root"
WARDEN_ADDR="http://127.0.0.1:${WARDEN_PORT:-8400}"
KEYCLOAK_ADDR="http://127.0.0.1:${KEYCLOAK_PORT:-8080}"
OAUTHAPP_VERSION="v3.4.0"

say() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

bao_api() {
  local method="$1" path="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -sS -X "$method" -H "X-Vault-Token: $BAO_TOKEN" -H "Content-Type: application/json" -d "$data" "$BAO_ADDR/v1/$path"
  else
    curl -sS -X "$method" -H "X-Vault-Token: $BAO_TOKEN" "$BAO_ADDR/v1/$path"
  fi
}

warden_api() {
  local method="$1" path="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -sS -X "$method" -H "X-Warden-Token: $WARDEN_TOKEN" -H "Content-Type: application/json" -d "$data" "$WARDEN_ADDR/v1/$path"
  else
    curl -sS -X "$method" -H "X-Warden-Token: $WARDEN_TOKEN" "$WARDEN_ADDR/v1/$path"
  fi
}

json() { python3 -c "import json,sys; print(json.dumps($1))"; }

# --- 0. Prerequisites --------------------------------------------------------

: "${GH_CLIENT_ID:?set GH_CLIENT_ID (see .env.example)}"
: "${GH_CLIENT_SECRET:?set GH_CLIENT_SECRET (see .env.example)}"

mkdir -p plugins .state

# --- 1. The OAuth app secret engine plugin -----------------------------------

if [ ! -x plugins/oauthapp ]; then
  say "Downloading the OAuth app secret engine ($OAUTHAPP_VERSION)"
  case "$(uname -m)" in
    arm64 | aarch64) arch=arm64 ;;
    *) arch=amd64 ;;
  esac
  url="https://github.com/openbao/openbao-plugin-secrets-oauthapp/releases/download/$OAUTHAPP_VERSION/openbao-plugin-secrets-oauthapp-$OAUTHAPP_VERSION-linux-$arch.tar.xz"
  curl -sSfL "$url" | tar -xJ -C plugins
  mv plugins/openbao-plugin-secrets-oauthapp-* plugins/oauthapp
  chmod +x plugins/oauthapp
fi

# --- 2. OpenBao and Keycloak -------------------------------------------------

say "Starting OpenBao and Keycloak"
docker compose up -d openbao keycloak
until curl -sf "$BAO_ADDR/v1/sys/health" >/dev/null 2>&1; do sleep 1; done
printf '    waiting for Keycloak'
until curl -sf "$KEYCLOAK_ADDR/realms/warden-demo/.well-known/openid-configuration" >/dev/null 2>&1; do
  printf '.'; sleep 2
done
printf ' ready\n'

say "Registering the OAuth app secret engine"
PLUGIN_SHA=$(shasum -a 256 plugins/oauthapp 2>/dev/null | awk '{print $1}' ||
             sha256sum plugins/oauthapp | awk '{print $1}')
bao_api PUT sys/plugins/catalog/secret/oauthapp \
  "$(json '{"sha256": "'"$PLUGIN_SHA"'", "command": "oauthapp", "type": "secret"}')" >/dev/null

say "Enabling transit and minting a scoped signer token"
bao_api POST sys/mounts/transit '{"type":"transit"}' >/dev/null 2>&1 || true

# The wildcard matters: Warden derives <prefix>-<alg> and needs an active key
# for BOTH RS256 and ES256 before its issuer reports ready. A policy covering
# only one leaves the issuer permanently not-ready with nothing naming why.
bao_api PUT sys/policies/acl/warden-signer "$(json '{"policy": """
path "transit/keys/warden-issuer-key-*"        { capabilities = ["create", "read", "update"] }
path "transit/keys/warden-issuer-key-*/rotate" { capabilities = ["update"] }
path "transit/sign/warden-issuer-key-*"        { capabilities = ["update"] }
"""}')" >/dev/null

SIGNER_TOKEN=$(bao_api POST auth/token/create '{"policies":["warden-signer"],"period":"24h"}' |
  python3 -c "import json,sys; print(json.load(sys.stdin)['auth']['client_token'])")

# --- 3. Warden ---------------------------------------------------------------

say "Rendering warden.hcl and starting Warden"
[ -f .state/seal.key ] || openssl rand 32 > .state/seal.key
sed "s|__SIGNER_TOKEN__|$SIGNER_TOKEN|" warden.hcl.tmpl > warden.hcl
docker compose up -d warden
# Warden answers 501 before `operator init` and 503 while sealed, so wait for
# the listener to respond at all rather than for a 2xx.
until curl -s -o /dev/null "$WARDEN_ADDR/v1/sys/health"; do sleep 1; done

# A stored token is only good while that Warden instance lives; inmem storage
# means a recreated container needs a fresh init.
WARDEN_TOKEN=""
if [ -f .state/root.token ]; then
  candidate=$(cat .state/root.token)
  if curl -sf -H "X-Warden-Token: $candidate" "$WARDEN_ADDR/v1/sys/mounts" >/dev/null 2>&1; then
    WARDEN_TOKEN="$candidate"
  fi
fi
if [ -n "$WARDEN_TOKEN" ]; then
  :
else
  say "Initializing Warden"
  # Over the API rather than the CLI: the published image is distroless, so
  # there is no shell to `docker compose exec` into. The static seal unseals
  # on its own once this returns.
  WARDEN_TOKEN=$(curl -sS -X PUT -H "Content-Type: application/json" "$WARDEN_ADDR/v1/sys/init" \
    -d '{"secret_shares":1,"secret_threshold":1,"recovery_shares":1,"recovery_threshold":1}' |
    python3 -c "import json,sys; print(json.load(sys.stdin)['root_token'])")
  echo "$WARDEN_TOKEN" > .state/root.token
fi
export WARDEN_TOKEN

# The static seal unseals on its own once initialized; give it a moment.
until [ "$(curl -s "$WARDEN_ADDR/v1/sys/health" |
           python3 -c 'import json,sys; print(json.load(sys.stdin)["sealed"])' 2>/dev/null)" = "False" ]; do
  sleep 1
done

# issuer_url must be https:// unless the host is loopback, so the issuer names
# itself on localhost. OpenBao does not resolve that name — setup.py points it
# at an explicit jwks_url on the compose network and matches bound_issuer to
# the name below. Split trust: what the issuer calls itself, and where its keys
# are fetched from, are two different things.
say "Enabling Warden's OIDC issuer (the signing key stays in OpenBao)"
warden_api POST sys/oidc-issuer/config \
  '{"enabled":true,"issuer_url":"http://localhost:8400"}' >/dev/null
warden_api GET sys/oidc-issuer/config |
  python3 -c "import json,sys; d=json.load(sys.stdin).get('data', {}); print('    ready:', d.get('ready'), '| signer:', json.dumps(d.get('signer')))"

./setup.py

echo
echo "OpenBao  : $BAO_ADDR       (root token: root)"
echo "Keycloak : $KEYCLOAK_ADDR  (admin/admin, realm warden-demo)"
echo "Warden   : $WARDEN_ADDR    (root token in .state/root.token)"
echo
echo "Next:  ./enroll.py alice     # one-time GitHub consent"
echo "       ./mcp-config.sh alice # prints the .mcp.json for Claude Code"
