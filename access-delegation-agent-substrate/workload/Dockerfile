FROM node:20-slim

ARG TARGETARCH
ARG KUBECTL_VERSION=v1.37.0

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl git tini \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSLo /usr/local/bin/kubectl \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
  && chmod +x /usr/local/bin/kubectl

RUN npm install -g @anthropic-ai/claude-code@2.1.322

# The home every run starts from. The server copies it to a fresh folder for
# each run, which the run's user owns, and clears what the run wrote when it
# ends. The template stays root's, so no run can change what the next one gets.
# Its kubeconfig, git setup and GitHub MCP server point at the local gateway.
# Warden's discovery server is reached directly, as the agent itself: the egress
# gateway puts the actor JWT in place of the placeholder. None holds a token.
ARG WARDEN_MCP_URL=http://warden.warden.svc.cluster.local:8400/v1/sys/mcp
COPY home/ /opt/agent-home/
RUN HOME=/opt/agent-home claude mcp add --scope user --transport http warden "${WARDEN_MCP_URL}" \
      --header "Authorization: Bearer placeholder" >/dev/null \
  && HOME=/opt/agent-home claude mcp add --scope user --transport http github http://127.0.0.1:8081/github-mcp >/dev/null \
  && chmod -R a+rX /opt/agent-home \
  && rm -rf /home/node

# The agent server stays root, so Claude Code, running as node, cannot read
# its memory. tini, as PID 1, reaps what a run leaves behind once the server
# has stopped it.
COPY server.js /server.js
ENTRYPOINT ["tini", "--", "node", "/server.js"]
