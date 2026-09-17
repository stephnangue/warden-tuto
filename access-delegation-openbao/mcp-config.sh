#!/usr/bin/env bash
#
# Prints the .mcp.json block for Claude Code, for one user.
#
#   ./mcp-config.sh alice
#   ./mcp-config.sh alice >> ~/.claude.json     # or paste into .mcp.json
#
# Both tokens are fetched here and embedded as headers: the agent's from a
# client-credentials grant, the user's from a password grant. Keycloak issues
# both, on different clients and with different audiences.
#
# Tokens last an hour. Re-run when they expire.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if [ -f .env ]; then set -a; . ./.env; set +a; fi

USER_NAME="${1:?usage: ./mcp-config.sh <username>   (e.g. alice)}"
KEYCLOAK="http://127.0.0.1:${KEYCLOAK_PORT:-8080}/realms/warden-demo/protocol/openid-connect/token"
WARDEN_URL="http://localhost:${WARDEN_PORT:-8400}/v1/github-mcp/role/agent/gateway/"

field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('access_token') or sys.exit('token request failed: '+json.dumps(d)[:200]))"; }

AGENT_JWT=$(curl -sS -X POST "$KEYCLOAK" \
  -d grant_type=client_credentials -d client_id=agent-1 -d client_secret=agent-1-secret | field)

USER_JWT=$(curl -sS -X POST "$KEYCLOAK" \
  -d grant_type=password -d client_id=warden-user \
  -d "username=$USER_NAME" -d password=demo | field)

python3 - "$WARDEN_URL" "$AGENT_JWT" "$USER_JWT" <<'PY'
import json, sys
url, agent, user = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "mcpServers": {
        "github-via-warden": {
            "type": "http",
            "url": url,
            "headers": {
                "X-Warden-Agent-Token": agent,
                "Authorization": f"Bearer {user}",
            },
        }
    }
}, indent=2))
PY
