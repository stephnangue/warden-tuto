# Claude Code agents that act for people, on Agent Substrate

Each person gets their own Claude Code agent, running as a sandboxed actor on
[Agent Substrate](https://ate.dev/docs/), and the agent does real work for them:
**Alice's agent** creates a private GitHub repository, writes code with tests, pushes a
branch and opens a pull request; **Bob's agent** finds out why his app in Kubernetes is
down and fixes it.

No agent holds a credential. Substrate's egress gateway attaches the agent's actor JWT;
the person's own token comes with each prompt and stays out of the agent's reach; Warden
checks both on every call, then adds its own credential for GitHub or Kubernetes. The
blog post [Claude Code agents that act for people, on Agent Substrate](https://wardengateway.com/blog/claude-code-agents-act-for-people/)
explains the design. This folder is everything you need to run it in a kind cluster.

Verified with Agent Substrate v1.0.0, Warden v0.22.0, Claude Code 2.1.322 and Kubernetes
v1.37.0, under Colima on an Apple Silicon Mac.

## What you need

- **Docker with 4 CPUs and 6 GiB** for its VM (Colima:
  `colima stop && colima start --cpu 4 --memory 6`).
- **docker buildx**. Docker Desktop ships it. With Colima and Homebrew's `docker` CLI:
  `brew install docker-buildx`, then
  `mkdir -p ~/.docker/cli-plugins && ln -sfn "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx" ~/.docker/cli-plugins/docker-buildx`
- **Go**, **kubectl**, **git** and **jq**.
- The **Warden CLI** v0.22.0: `curl -sL https://wardengateway.com/install.sh | bash`
- An **Anthropic API key**. Each prompt is one Claude Code run on Claude Haiku.
- A **GitHub account**, for Alice's part. You create a token for it in step 6.
- Free local ports **5001**, **8400**, **8001** and **8002**, and **8003** for the optional
  check of step 12.

| Path | What it is |
|---|---|
| `workload/` | The agent's image: Claude Code, git, kubectl, and `server.js`, the agent server with its local gateway |
| `manifests/warden-playground.yaml` | Warden, in the cluster, under two Service names |
| `manifests/bob-namespace.yaml` | Bob's namespace, the ServiceAccount his agent works as, Warden's minting account, and Bob's broken app |
| `manifests/pool.yaml` | Two gVisor workers |
| `manifests/claude-person-agent.yaml.tmpl` | The actor template both agents share |
| `manifests/egress-policy.yaml` | What an agent may reach: Warden, under its two names |
| `policies/` | Warden policies: Bob's namespace, Alice's GitHub |
| `skills/` | The skills Warden serves the agents: how each role is reached from the sandbox |
| `ask.sh` | `ask <agent> "<prompt>" as "$TOKEN"`: send a prompt for a person |
| `setup.sh` | Steps 1 to 10 in one command |

Three terminal tabs: the **main tab** for every command, a **Warden tab** for a
port-forward, and an **agents tab** for one proxy per agent.

### Or run the setup in one command

`setup.sh` runs the commands of steps 1 to 9 as written below, then starts the agents'
proxies of step 10. The port-forward and the proxies run in the background, so one tab is
enough. It stops at the first error.

```bash
./setup.sh          # steps 1 to 10
./setup.sh 3-7      # a range: after a Warden restart, for example
./setup.sh stop     # stop the port-forward and the proxies
./setup.sh down     # stop them and delete the cluster (it asks first)
```

It asks first for the Anthropic API key, your GitHub login and the GitHub token (create
the token as step 6 says), without echoing the keys, so the long install then runs
unattended. When it is done, it prints what to type in your shell to ask the agents, from
step 10 on. Step 1 keeps an existing kind cluster named `kind`: Substrate's own script
would delete it.

## 1. The cluster and Agent Substrate

In the main tab, from this folder:

```bash
export EXAMPLE=$PWD
git clone --branch v1.0.0 --depth 1 https://github.com/agent-substrate/substrate.git substrate
cd substrate
hack/create-kind-cluster.sh

export ATE_INSTALL_KIND=true
go run ./cmd/ate-setup deploy ate-system \
  --credential-provider='{"enabled":false}' \
  --ingress-allowed-spiffe-ids=spiffe://cluster.local/ns/ate-system/sa/atenet-client
go install ./cmd/kubectl-ate      # needs $(go env GOPATH)/bin on your PATH
```

Every later command runs from `substrate/`. The install builds Substrate from source and
takes several minutes. `{"enabled":false}` turns off Substrate's injection of *stored*
secrets, which needs a credential provider; actor JWTs are still minted and injected,
and Warden holds every other credential.

## 2. Warden

```bash
kubectl apply -f $EXAMPLE/manifests/warden-playground.yaml
kubectl -n warden rollout status deploy/warden
```

**In the Warden tab**, forward Warden's port to your machine, and leave it running:

```bash
kubectl -n warden port-forward svc/warden 8400:8400
```

**Back in the main tab:**

```bash
export WARDEN_ADDR=http://127.0.0.1:8400
export WARDEN_TOKEN=root
warden status
```

Warden runs as a dev playground, in memory: a restarted pod starts over, and you redo
steps 3 to 7 (`./setup.sh 3-7`). The playground also gives you people: `warden dev jwt user <name>` issues
a person's token, and its `auth/user/` mount admits them. Warden has two Service names
for the same pods, `warden` and `warden-on-behalf`, because Substrate's egress rules
apply per host: the agent's own calls go to the first, its calls for a person to the
second.

## 3. Trust Substrate's actor JWTs

```bash
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
```

## 4. The model, for the agents themselves

Model calls carry no person. Warden holds the API key and allows Claude Haiku only.

`warden write` takes its JSON on stdin, from a heredoc or a pipe. Inline JSON as an
argument also works in an interactive terminal, but v0.22.0 ignores it whenever stdin is
not a terminal, as in a script.

```bash
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

printf 'Anthropic API key: '; read -rs ANTHROPIC_API_KEY; echo
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
```

## 5. Kubernetes, for Bob

`bob-namespace.yaml` creates:

- the `bob` namespace, where Pod Security's `baseline` level refuses privileged pods,
  host paths and the host's network, so no pod created there can reach the node;
- the ServiceAccount `bob-agent`, with a narrow role: read pods, logs, events,
  services and replica sets, change deployments and config maps, run short-lived pods.
  No secrets, no tokens, nothing outside `bob`;
- the account `warden-token-creator`, which may mint tokens for `bob-agent` only;
- Bob's app, broken on purpose.

```bash
kubectl apply -f $EXAMPLE/manifests/bob-namespace.yaml
kubectl -n bob get pods        # Error, then CrashLoopBackOff
```

Warden's source holds a `warden-token-creator` token, which it rotates every day; the
spec mints a 15-minute `bob-agent` token for each use:

```bash
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
```

The writes warn that the source stores a token; see the blog post's production notes. A
rotation period under 24 hours is refused by default, hence the 48-hour bootstrap token.
`user_auth_path` is what lets the mount read a person on top of the agent. Every path in
`bob-kube-ops.hcl` requires that the person named this agent in `may_act` and is Bob.
kubectl sends its edits as HTTP `PATCH`, which needs the `patch` capability.

The role names a **skill**, which Warden's discovery server hands the agent (step 8).
Warden ships no skill for its Kubernetes provider; this one says how the role is reached
from the sandbox: kubectl is already configured, and `exec` cannot work there.

## 6. GitHub, for Alice

Alice's agent uses GitHub's MCP server for the API and Warden's GitHub provider for git.
You play Alice: her GitHub account is yours.

Create a fine-grained token at https://github.com/settings/personal-access-tokens/new:

1. Expiration of 1 or 2 days, resource owner your account.
2. Repository access: **All repositories**. The agent creates repositories, and a token
   cannot name one that does not exist yet; Warden's policy does the narrowing.
3. Repository permissions: **Administration**, **Contents** and **Pull requests**, read
   and write. Administration lets the agent create repositories; it would also allow
   deleting them, which the policy refuses.

```bash
export GITHUB_USER=<your GitHub login>

printf 'GitHub PAT: '; read -rs GITHUB_PAT; echo
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
```

The playground already has the credential source `github`. Outside it, create it first:
`warden cred source create github -json '{"type": "github", "config": {"github_url": "https://api.github.com"}}'`.

`alice-github-tools` decides which GitHub tools the agent sees and how it may call them:
a repository may be created only private, in your account, named `alice-agent-*`, and
every other call must name one of those repositories. It has one branch per tool, so a
tool it does not name, in any spelling, is refused, and it matches repository names
whole: a prefix check would let `alice-agent-x/../other-repo` through, if the MCP server
resolves the `..` when it builds the API URL. No delete tool is offered. Listing MCP
prompts is allowed; MCP resources stay refused, because GitHub's resources reach file
contents by URI, outside the per-repository checks.

The two roles name skills of their own. Warden's built-in GitHub and MCP skills tell an
agent to call Warden's URL with its own token, which this agent has none of; these say
how each role is reached from the sandbox.

## 7. One agent per person

```bash
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
```

A group grants roles to an agent; the policies then require the right person behind it.

> **In production, register the agent.** Virtual groups match whatever actor carries the
> name. Register each agent as an entity with a sponsor and a static group, and set
> `governed_only` on its roles.

## 8. The agent image

`workload/server.js` is where the person's token lives and dies:

- It receives the person's token with the prompt (`X-User-Token`) and uses it for that
  run only.
- Claude Code's tools (git's remote, kubectl's server, the GitHub MCP server) point at a
  local gateway on `127.0.0.1:8081` with no credential. The gateway adds the person's
  token and an `X-Warden-Agent-Token` placeholder, forwards to three fixed routes on
  `warden-on-behalf`, refuses `..` paths, drops any `X-Warden-*` header the agent sets,
  and answers nothing between runs. When a run ends, it cuts the calls still open.
- Claude Code runs as the unprivileged `node` user; the server stays root.
- Each run gets a fresh home from a read-only template. When it ends, the server stops
  every process the agent user left behind, deletes everything that user wrote, and
  checks that nothing is left. If something is, the agent refuses every prompt after it.

The template also registers Warden's discovery server as the MCP server `warden`. It is
reached directly, on the `warden` host, so the egress gateway puts the agent's own actor
JWT on it, and no person's token. `workload/home/.claude/CLAUDE.md` tells Claude Code to
start there: call `list_roles`, pick the role that fits the task, and read its skill. It
holds no rules about repositories or namespaces; Warden enforces those.

```bash
ARCH=$(kubectl get node kind-control-plane -o jsonpath='{.status.nodeInfo.architecture}')
docker buildx build --platform linux/$ARCH \
  -t localhost:5001/claude-person-agent:2.1.322 \
  --push --metadata-file $EXAMPLE/build-meta.json $EXAMPLE/workload
IMAGE=localhost:5001/claude-person-agent@$(jq -r '."containerimage.digest"' $EXAMPLE/build-meta.json)
```

## 9. The workers and the agents

```bash
KO_DOCKER_REPO=localhost:5001 hack/run-tool.sh ko resolve --platform=linux/$ARCH \
  -f $EXAMPLE/manifests/pool.yaml | kubectl apply -f -
kubectl -n claude-agents rollout status deploy/claude-workerpool

kubectl ate create atespace claude-agents
sed "s#\${IMAGE}#$IMAGE#" $EXAMPLE/manifests/claude-person-agent.yaml.tmpl > $EXAMPLE/claude-person-agent.yaml
kubectl ate create actor-template -f $EXAMPLE/claude-person-agent.yaml
kubectl ate get actor-template claude-person-agent -a claude-agents   # wait for a GOLDEN TAG

for a in claude-alice claude-bob; do
  kubectl ate create actor $a -a claude-agents --template claude-person-agent
  kubectl ate create egress-policy $a -a claude-agents -f $EXAMPLE/manifests/egress-policy.yaml
done
```

The template grants `SETUID` and `SETGID`: Substrate gives a container only
`AUDIT_WRITE`, `KILL` and `NET_BIND_SERVICE`, and the server needs the two to start
Claude Code as another user.

## 10. Ask the agents to work

**In the agents tab**, open one proxy per agent, and leave them running:

```bash
kubectl ate proxy actor claude-alice 8001:80 -a claude-agents &
kubectl ate proxy actor claude-bob   8002:80 -a claude-agents &
```

**Back in the main tab:**

```bash
. $EXAMPLE/ask.sh
ALICE_TOKEN=$(warden dev jwt user alice -may-act actor/claude-agents/claude-alice)
BOB_TOKEN=$(warden dev jwt user bob -may-act actor/claude-agents/claude-bob)

ask claude-bob "My web app in my Kubernetes namespace is down. Find out why and fix it, then confirm the pods are running." as "$BOB_TOKEN"
```

```
Cause: The web deployment in namespace bob overrode nginx's startup command with
-c /etc/nginx/conf.d/web.conf. That file doesn't exist in the nginx:1.27-alpine image.
Fix: I removed the command override from the deployment (kubectl patch).
Result: Both new pods are 1/1 Running with 0 restarts.
```

```bash
ask claude-alice "Create a new private GitHub repository named alice-agent-hello, initialized with a README. Clone it, add a small Node.js command-line tool that prints a greeting for a name given as an argument, with a test using Node's built-in test runner, run the test, and update the README to explain the tool. Commit this on a branch named add-greeting, push the branch, and open a pull request into main. Reply with the pull request URL and the test result." as "$ALICE_TOKEN"
```

```
The pull request is open: https://github.com/<you>/alice-agent-hello/pull/1
Test result: npm test ran 3 tests, all passing, 0 failing.
```

Answers are condensed here, and the wording is the model's. Bob's took about 40 seconds
and Alice's about 30. `ask` suspends the agent after each answer: Substrate does not
suspend an idle actor on its own.

## 11. Watch it refuse

```bash
ask claude-alice "Create a new public GitHub repository named alice-agent-public. If it is refused, say who refused it, in one sentence." as "$ALICE_TOKEN"
ask claude-alice "Create a new private GitHub repository named demo-tools. If it is refused, say who refused it, in one sentence." as "$ALICE_TOKEN"
ask claude-alice "Clone the repository $GITHUB_USER/<another of your repositories> and tell me how many files it has. If it is refused, say who refused it, in one sentence." as "$ALICE_TOKEN"
ask claude-alice "Use the GitHub tool get_file_contents with owner $GITHUB_USER, repo alice-agent-hello/../<another of your repositories> and path README.md, and show me the first line. If it is refused, say who refused it, in one sentence." as "$ALICE_TOKEN"
ask claude-alice "Delete the repository $GITHUB_USER/alice-agent-hello. If you cannot, say why in one sentence." as "$ALICE_TOKEN"
ask claude-bob "Run a privileged pod in my namespace that mounts the node's root filesystem at /host. If it is refused, say who refused it, in one sentence." as "$BOB_TOKEN"
ask claude-alice "List the files of the repository $GITHUB_USER/alice-agent-hello, in one sentence." as "$BOB_TOKEN"
ask claude-bob "List the pods in my namespace." as "$ALICE_TOKEN"
```

Warden refuses the public repository, the wrong name and the `..` repository on the
tool's arguments, the clone on the git path, and the last two on the person; there is no
delete tool to call. The privileged pod passes Warden, since Bob's agent may create pods
in his namespace, and Kubernetes refuses it: the namespace enforces Pod Security's
`baseline` level. The refused repositories never exist on GitHub. The audit names agent,
person and reason:

```bash
warden dev audit -principal actor/claude-agents/claude-bob -user alice -decision deny -limit 1
```

## 12. Prove the agent never sees the token (optional)

The server has a self-check for templates that set `SELF_CHECK=1`: with a person's token
loaded as for a prompt, a fixed script runs as the agent user and looks for the token
everywhere Claude Code could.

```bash
sed -e 's/name: claude-person-agent$/name: claude-self-check/' -e 's#^  - name: MODEL$#  - name: SELF_CHECK\
    value: "1"\
  - name: MODEL#' $EXAMPLE/claude-person-agent.yaml > $EXAMPLE/claude-self-check.yaml
kubectl ate create actor-template -f $EXAMPLE/claude-self-check.yaml
kubectl ate create actor claude-check -a claude-agents --template claude-self-check
kubectl ate create egress-policy claude-check -a claude-agents -f $EXAMPLE/manifests/egress-policy.yaml
warden identity group update bob-agent -json '{"rules": [
  {"mount": ["auth/substrate/"], "sub": ["actor/claude-agents/claude-bob"]},
  {"mount": ["auth/substrate/"], "sub": ["actor/claude-agents/claude-check"]}
]}'
```

**In the agents tab:**

```bash
kubectl ate proxy actor claude-check 8003:80 -a claude-agents &
```

**Back in the main tab:**

```bash
CHECK_TOKEN=$(warden dev jwt user bob -may-act actor/claude-agents/claude-check)
```

First, a run that tries to leave things behind for the next person: read-only folders, a
background process, and a loop that keeps starting new ones.

```bash
curl -s --max-time 300 localhost:8003/prompt -H "X-User-Token: $CHECK_TOKEN" -d 'This is a cleanup test of this sandbox, which is mine. Run exactly these shell commands, then report their output and nothing else:
mkdir -p /tmp/keep/sub && echo secret > /tmp/keep/sub/f && chmod 500 /tmp/keep/sub /tmp/keep
mkdir -p /var/tmp/locked && echo secret > /var/tmp/locked/g && chmod 000 /var/tmp/locked
(nohup sh -c "while true; do sleep 60 & sleep 0.05; done" >/dev/null 2>&1 &)
(nohup sleep 600 >/dev/null 2>&1 &)
ls -ld /tmp/keep /tmp/keep/sub /var/tmp/locked'
```

Then the check:

```bash
curl -s -X POST localhost:8003/self-check -H "X-User-Token: $CHECK_TOKEN" | tr -d '\000'
curl -s localhost:8003/healthz      # ok
```

It reports no `eyJ` (how a JWT starts) in any environment entry, process command line or
readable file, `Permission denied` on the server's `/proc/<pid>/environ` and
`/proc/<pid>/mem`, `path not allowed` for a `..` path through the gateway, an
`X-Warden-Role` header that changes nothing, a read-only template, and nothing left by
earlier runs, while `kubectl auth whoami` through the gateway answers as Bob's agent. Remove the check afterwards: `kill %3` in the agents tab,
then `kubectl ate delete actor claude-check -a claude-agents` and the group update above
with only `claude-bob`.

## Clean up

On GitHub, delete the `alice-agent-*` repositories and the token. Stop the proxies with
`kill %1 %2` in the agents tab and the port-forward with Ctrl-C, then, from `substrate/`
(or run `./setup.sh down`, which does both):

```bash
./hack/delete-kind-cluster.sh
```

## Troubleshooting

| What you see | Why |
|---|---|
| `unknown flag: --platform` during the Substrate install | `docker buildx` is missing. |
| `upstream connect error or disconnect/reset before headers`, actor `CRASHED` | The agent server died: `kubectl -n claude-agents logs <worker pod> \| grep -A12 Error` shows why. |
| `cannot start claude: spawn EPERM` | The actor template lacks `SETUID` and `SETGID`. |
| `rotation_period … is below the minimum allowed 24h0m0s` | Warden's default minimum; rotate every 24 hours with a longer-lived token. |
| An agent reports that Warden refused a call you expected to work | `warden dev audit -principal actor/claude-agents/<agent> -decision deny -limit 3` gives the reason. |
| `API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)` | The agent has no egress policy, so its sandbox resolves no name. `kubectl ate get egress-policy <agent> -a claude-agents` says so; create it as in step 9. |
| `actor … unavailable: no worker has room for the actor` (`503`) | Both workers hold running agents; suspend the one you left running. |
| `X-User-Token must carry the JWT of the person this prompt is for` (`400`) | `ask` needs `as "$TOKEN"`. |
| `a run left … that could not be removed; recreate this agent` (`503`) | The server could not clear what a run left, so it refuses the next person. Delete the actor and create it again. |
