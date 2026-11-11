#!/usr/bin/env bash
# Runs this tutorial's setup: the README's commands, step by step.
#
#   ./setup.sh          steps 1 to 10: the cluster, Substrate, Warden, the agents
#                       and their proxies
#   ./setup.sh 3-7      a range of steps, e.g. after Warden's pod restarted (it
#                       keeps everything in memory)
#   ./setup.sh 6        one step
#   ./setup.sh stop     stop the port-forward and the proxies it started
#
# It asks first for what the steps need: the Anthropic API key (step 4), your
# GitHub login and token (step 6). Keys are read without echo, or taken from
# ANTHROPIC_API_KEY, GITHUB_USER and GITHUB_PAT. The port-forward (step 2) and
# the agents' proxies (step 10) run in the background, logging to .setup/.
# It stops at the first error.
set -euo pipefail

EXAMPLE=$(cd "$(dirname "$0")" && pwd)
SUBSTRATE=$EXAMPLE/substrate
STATE=$EXAMPLE/.setup
export WARDEN_ADDR=${WARDEN_ADDR:-http://127.0.0.1:8400}
export WARDEN_TOKEN=${WARDEN_TOKEN:-root}

say() { printf '\n== %s\n' "$*"; }

listening() {
  if command -v lsof >/dev/null; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    nc -z 127.0.0.1 "$1" 2>/dev/null
  fi
}

# background NAME PORT COMMAND...: runs COMMAND detached, unless PORT is
# already taken, and waits until it listens.
background() {
  local name=$1 port=$2
  shift 2
  if listening "$port"; then
    echo "port $port is in use: taking it as $name"
    return
  fi
  mkdir -p "$STATE"
  nohup "$@" >"$STATE/$name.log" 2>&1 &
  echo $! >"$STATE/$name.pid"
  for _ in $(seq 1 60); do
    listening "$port" && return
    sleep 1
  done
  echo "$name did not start: see $STATE/$name.log" >&2
  exit 1
}

stop_background() {
  for f in "$STATE"/*.pid; do
    [ -e "$f" ] || continue
    kill "$(cat "$f")" 2>/dev/null || true
    rm -f "$f"
  done
  echo "stopped"
}

port_forward() {
  listening 8400 || background port-forward 8400 kubectl -n warden port-forward svc/warden 8400:8400
}

agent_image() {
  ARCH=$(kubectl get node kind-control-plane -o jsonpath='{.status.nodeInfo.architecture}')
  if [ -f "$EXAMPLE/build-meta.json" ]; then
    IMAGE=localhost:5001/claude-person-agent@$(jq -r '."containerimage.digest"' $EXAMPLE/build-meta.json)
  fi
}

step1() {
  say "1. The cluster and Agent Substrate"
  [ -d "$SUBSTRATE" ] || git clone --branch v1.0.0 --depth 1 https://github.com/agent-substrate/substrate.git "$SUBSTRATE"
  cd "$SUBSTRATE"
  # create-kind-cluster.sh deletes a cluster of the same name first.
  if hack/kind.sh get clusters 2>/dev/null | grep -qx kind; then
    echo "the kind cluster 'kind' exists: keeping it"
  else
    hack/create-kind-cluster.sh
  fi

  export ATE_INSTALL_KIND=true
  go run ./cmd/ate-setup deploy ate-system \
    --credential-provider='{"enabled":false}' \
    --ingress-allowed-spiffe-ids=spiffe://cluster.local/ns/ate-system/sa/atenet-client
  go install ./cmd/kubectl-ate
}

step2() {
  say "2. Warden"
  kubectl apply -f $EXAMPLE/manifests/warden-playground.yaml
  kubectl -n warden rollout status deploy/warden
  port_forward
  warden status
}

step3() {
  say "3. Trust Substrate's actor JWTs"
  port_forward
  kubectl get clustertrustbundle servicedns.podcert.ate.dev:identity:primary-bundle \
    -o jsonpath='{.spec.trustBundle}' > $EXAMPLE/substrate-idp-ca.pem

  warden auth enable -path=substrate -description="Agent Substrate actors, by their actor JWT" jwt

  jq -n --rawfile ca $EXAMPLE/substrate-idp-ca.pem '{
    "oidc_discovery_url": "https://idp.ate-system.svc",
    "oidc_discovery_ca_pem": $ca,
    "bound_issuer": "https://idp.ate-system.svc",
    "bound_audiences": ["warden"],
    "entity_kind": "agent",
    "facts": {
      "/actor.ate.dev/atespace": "atespace",
      "/actor.ate.dev/actorName": "actor"
    }
  }' | warden write auth/substrate/config
}

step4() {
  say "4. The model, for the agents themselves"
  port_forward
  warden provider enable -description="The Anthropic API, for Agent Substrate actors" anthropic
  warden write anthropic/config <<'EOF'
{
  "anthropic_url": "https://api.anthropic.com",
  "auto_auth_path": "auth/substrate/",
  "timeout": "120s"
}
EOF

  warden cred source create anthropic-src -json '{
    "type": "apikey",
    "config": {
      "api_url": "https://api.anthropic.com",
      "verify_endpoint": "/v1/models",
      "auth_header_type": "custom_header",
      "auth_header_name": "x-api-key",
      "extra_headers": "anthropic-version:2023-06-01",
      "display_name": "Anthropic"
    }
  }'

  jq -n --arg k "$ANTHROPIC_API_KEY" '{
    "source": "anthropic-src",
    "config": {
      "api_key": $k
    }
  }' | warden cred spec create anthropic-agents -json -
  unset ANTHROPIC_API_KEY

  warden policy write actor-claude-models - <<'EOF'
path "anthropic/role/+/gateway/v1/messages" {
  capabilities = ["create", "update"]
  condition    = "has(request.data.model) && request.data.model.startsWith('claude-haiku')"
}
path "anthropic/role/+/gateway/v1/messages/count_tokens" {
  capabilities = ["create", "update"]
}
EOF

  warden role create actor-claude -json '{
    "description": "The Anthropic API for the calling actor: Claude Haiku models only.",
    "policies": ["actor-claude-models"],
    "cred_spec_name": "anthropic-agents",
    "provider_path": "anthropic/"
  }'
}

step5() {
  say "5. Kubernetes, for Bob"
  port_forward
  kubectl apply -f $EXAMPLE/manifests/bob-namespace.yaml
  kubectl -n bob get pods || true

  CA_DATA=$(kubectl get configmap kube-root-ca.crt -n warden -o jsonpath='{.data.ca\.crt}' | base64 | tr -d '\n')
  SOURCE_TOKEN=$(kubectl create token warden-token-creator -n warden --duration=48h)

  jq -n --arg token "$SOURCE_TOKEN" --arg ca "$CA_DATA" '{
    "type": "kubernetes",
    "rotation_period": "24h",
    "config": {
      "kubernetes_url": "https://kubernetes.default.svc",
      "ca_data": $ca,
      "token": $token,
      "source_service_account": "warden-token-creator",
      "source_namespace": "warden",
      "source_token_ttl": "48h"
    }
  }' | warden cred source create k8s-source -json -
  unset SOURCE_TOKEN

  warden cred spec create bob-k8s -json '{
    "source": "k8s-source",
    "config": {
      "service_account": "bob-agent",
      "namespace": "bob",
      "ttl": "15m"
    }
  }'

  warden provider enable -path=k8s-actor -description="The kind cluster's Kubernetes API, for agents acting for a person" kubernetes
  jq -n --arg ca "$CA_DATA" '{
    "kubernetes_url": "https://kubernetes.default.svc",
    "ca_data": $ca,
    "auto_auth_path": "auth/substrate/",
    "user_auth_path": "auth/user/"
  }' | warden write k8s-actor/config

  warden policy write bob-kube-ops $EXAMPLE/policies/bob-kube-ops.hcl
  warden skill create sandbox-kubernetes -category=custom \
    -description="Use kubectl in the namespace of the person you act for, from an Agent Substrate sandbox, through its local gateway." \
    -body-file=$EXAMPLE/skills/sandbox-kubernetes.md
  warden role create kube-ops -json '{
    "description": "The Kubernetes API for the person this agent acts for, in their own namespace only.",
    "policies": ["bob-kube-ops"],
    "cred_spec_name": "bob-k8s",
    "provider_path": "k8s-actor/",
    "skill": "sandbox-kubernetes"
  }'
}

step6() {
  say "6. GitHub, for Alice"
  port_forward
  warden cred spec create alice-github -json - <<EOF
{
  "source": "github",
  "min_ttl": 3600,
  "max_ttl": 86400,
  "config": {
    "mint_method": "pat",
    "token": "$GITHUB_PAT"
  }
}
EOF
  unset GITHUB_PAT

  warden provider enable -path=github-mcp-actor -description="GitHub's MCP server, for agents acting for a person" mcp
  warden write github-mcp-actor/config <<'EOF'
{
  "mcp_url": "https://api.githubcopilot.com/mcp",
  "auto_auth_path": "auth/substrate/",
  "user_auth_path": "auth/user/",
  "timeout": "2m"
}
EOF

  warden provider enable -path=github-actor -description="GitHub git, for agents acting for a person" github
  warden write github-actor/config <<'EOF'
{
  "github_url": "https://api.github.com",
  "auto_auth_path": "auth/substrate/",
  "user_auth_path": "auth/user/",
  "timeout": "2m"
}
EOF

  sed "s/\${GITHUB_USER}/$GITHUB_USER/g" $EXAMPLE/policies/alice-github-access.hcl.tmpl | warden policy write alice-github-access -
  sed "s/\${GITHUB_USER}/$GITHUB_USER/g" $EXAMPLE/policies/alice-github-tools.hcl.tmpl | warden policy write -type mcp alice-github-tools -
  sed "s/\${GITHUB_USER}/$GITHUB_USER/g" $EXAMPLE/policies/alice-github-git.hcl.tmpl | warden policy write alice-github-git -

  warden skill create sandbox-github -category=custom \
    -description="Use GitHub's MCP tools for the person you act for, from an Agent Substrate sandbox, through its local gateway." \
    -body-file=$EXAMPLE/skills/sandbox-github.md
  warden skill create sandbox-git -category=custom \
    -description="Clone and push on GitHub for the person you act for, from an Agent Substrate sandbox, through its local gateway." \
    -body-file=$EXAMPLE/skills/sandbox-git.md

  warden role create github-tools -json '{
    "description": "GitHub, through its MCP server, for the person this agent acts for: create private repositories and open pull requests.",
    "policies": ["alice-github-access", "alice-github-tools"],
    "cred_spec_name": "alice-github",
    "provider_path": "github-mcp-actor/",
    "skill": "sandbox-github"
  }'
  warden role create github-git -json '{
    "description": "git clone, fetch and push on GitHub, for the person this agent acts for.",
    "policies": ["alice-github-git"],
    "cred_spec_name": "alice-github",
    "provider_path": "github-actor/",
    "skill": "sandbox-git"
  }'
}

step7() {
  say "7. One agent per person"
  port_forward
  warden identity group create alice-agent -json '{
    "type": "virtual",
    "description": "Alice'"'"'s Claude Code agent, by its actor JWT.",
    "roles": ["actor-claude", "github-tools", "github-git"],
    "rules": [
      {
        "mount": ["auth/substrate/"],
        "sub": ["actor/claude-agents/claude-alice"]
      }
    ]
  }'

  warden identity group create bob-agent -json '{
    "type": "virtual",
    "description": "Bob'"'"'s Claude Code agent, by its actor JWT.",
    "roles": ["actor-claude", "kube-ops"],
    "rules": [
      {
        "mount": ["auth/substrate/"],
        "sub": ["actor/claude-agents/claude-bob"]
      }
    ]
  }'
}

step8() {
  say "8. The agent image"
  agent_image
  docker buildx build --platform linux/$ARCH \
    -t localhost:5001/claude-person-agent:2.1.322 \
    --push --metadata-file $EXAMPLE/build-meta.json $EXAMPLE/workload
  agent_image
}

step9() {
  say "9. The workers and the agents"
  agent_image
  if [ -z "${IMAGE:-}" ]; then
    echo "no agent image yet: run step 8 first" >&2
    exit 1
  fi
  cd "$SUBSTRATE"
  KO_DOCKER_REPO=localhost:5001 hack/run-tool.sh ko resolve --platform=linux/$ARCH \
    -f $EXAMPLE/manifests/pool.yaml | kubectl apply -f -
  kubectl -n claude-agents rollout status deploy/claude-workerpool

  # What a failed run already created is kept, so the step can run again.
  exists atespace claude-agents || kubectl ate create atespace claude-agents
  sed "s#\${IMAGE}#$IMAGE#" $EXAMPLE/manifests/claude-person-agent.yaml.tmpl > $EXAMPLE/claude-person-agent.yaml
  exists actor-template claude-person-agent -a claude-agents ||
    kubectl ate create actor-template -f $EXAMPLE/claude-person-agent.yaml

  printf 'waiting for the template to take its golden snapshot'
  for _ in $(seq 1 120); do
    golden && break
    printf .
    sleep 5
  done
  echo
  if ! golden; then
    kubectl ate get actor-template claude-person-agent -a claude-agents >&2
    echo "the template has no golden snapshot after 10 minutes" >&2
    exit 1
  fi

  for a in claude-alice claude-bob; do
    exists actor $a -a claude-agents ||
      kubectl ate create actor $a -a claude-agents --template claude-person-agent
    has_egress_policy $a ||
      kubectl ate create egress-policy $a -a claude-agents -f $EXAMPLE/manifests/egress-policy.yaml
  done
}

exists() { kubectl ate get "$@" >/dev/null 2>&1; }

# For an actor without one, kubectl ate says so and still exits 0.
has_egress_policy() {
  local out
  out=$(kubectl ate get egress-policy "$1" -a claude-agents 2>&1) && ! grep -q 'has no egress policy' <<<"$out"
}

# The template is ready once its status names a golden snapshot: goldenTag
# carries the snapshot's atespace and name.
golden() {
  kubectl ate get actor-template claude-person-agent -a claude-agents -o yaml 2>/dev/null |
    grep -A3 'goldenTag:' | grep -Eq 'name: *"?[0-9a-f]{8}-'
}

step10() {
  say "10. The agents' proxies"
  background proxy-claude-alice 8001 kubectl ate proxy actor claude-alice 8001:80 -a claude-agents
  background proxy-claude-bob 8002 kubectl ate proxy actor claude-bob 8002:80 -a claude-agents
}

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit "${1:-2}"
}

steps=${1:-1-10}
case "$steps" in
  stop) stop_background; exit 0 ;;
  -h | --help | help) usage 0 ;;
  [0-9]-[0-9] | [0-9]-10 | 10-10) first=${steps%-*} last=${steps#*-} ;;
  [0-9] | 10) first=$steps last=$steps ;;
  *) usage ;;
esac
if [ "$first" -lt 1 ] || [ "$first" -gt "$last" ]; then usage; fi

in_range() { [ "$first" -le "$1" ] && [ "$1" -le "$last" ]; }

for c in git go docker kubectl jq warden curl; do
  command -v "$c" >/dev/null || { echo "missing: $c (see What you need in README.md)" >&2; exit 1; }
done
if { in_range 1 || in_range 8; } && ! docker buildx version </dev/null >/dev/null 2>&1; then
  echo "missing: docker buildx (see What you need in README.md)" >&2
  exit 1
fi
export PATH="$(go env GOPATH </dev/null)/bin:$PATH"

# Everything to type comes first, so the long install can run unattended.
if in_range 4 && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  printf 'Anthropic API key (hidden): '
  read -rs ANTHROPIC_API_KEY || true
  echo
  [ -n "$ANTHROPIC_API_KEY" ] || { echo "the Anthropic API key is empty" >&2; exit 1; }
fi
if in_range 6; then
  if [ -z "${GITHUB_USER:-}" ]; then
    printf 'GitHub username (not the token): '
    read -r GITHUB_USER || true
  fi
  case "$GITHUB_USER" in
    "") echo "the GitHub username is empty" >&2; exit 1 ;;
    github_pat_* | ghp_* | gho_* | ghu_* | ghs_*)
      echo "that is a token, not a username: run ./setup.sh again and give your GitHub username first" >&2
      exit 1 ;;
  esac
  if [ -z "${GITHUB_PAT:-}" ]; then
    printf 'GitHub token (hidden): '
    read -rs GITHUB_PAT || true
    echo
  fi
  [ -n "$GITHUB_PAT" ] || { echo "the GitHub token is empty" >&2; exit 1; }
fi
exec </dev/null

for ((n = first; n <= last; n++)); do
  (
    cd "$EXAMPLE"
    "step$n"
  )
done

if [ "$last" -ge 10 ]; then
  cat <<EOF

Ready. In your shell, from this folder:

  export WARDEN_ADDR=$WARDEN_ADDR WARDEN_TOKEN=$WARDEN_TOKEN GITHUB_USER=${GITHUB_USER:-<your GitHub login>}
  . ./ask.sh
  ALICE_TOKEN=\$(warden dev jwt user alice -may-act actor/claude-agents/claude-alice)
  BOB_TOKEN=\$(warden dev jwt user bob -may-act actor/claude-agents/claude-bob)

then ask the agents, from step 10 of README.md. ./setup.sh stop stops the
port-forward and the proxies.
EOF
fi
