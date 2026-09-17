# warden-tuto

Hands-on, self-contained tutorials for [Warden](https://github.com/stephnangue/warden) — the
identity-aware egress proxy for AI agents. Each tutorial is a single folder you can clone, `cd`
into, and bring up with one command.

## How to use

```bash
git clone https://github.com/stephnangue/warden-tuto.git
cd warden-tuto/<tutorial-folder>
# follow that folder's README.md
```

Each folder ships its own `docker-compose.yml` and a `README.md` walkthrough, and stands entirely on
its own — pick whichever tutorial you want and run it in isolation.

## Prerequisites

Shared across the tutorials (each README repeats what it actually needs):

- **Docker** and **Docker Compose**
- **[Claude Code](https://docs.claude.com/en/docs/claude-code)** — the MCP client used to drive the
  demos
- The **Warden CLI** on your `PATH`, **v0.20.0 or newer** — each tutorial's walkthrough installs
  the latest release:
  ```bash
  curl -sL https://wardengateway.com/install | bash
  ```
- Any per-tutorial credential the walkthrough calls out (e.g. a GitHub PAT)

## Tutorials

| Tutorial | What you'll learn |
|----------|-------------------|
| [policy-mcp-tool-filtering](./policy-mcp-tool-filtering/) | Filter which MCP tools an agent can see and call, using a Warden policy — demonstrated live through Claude, before and after the filter. Warden + Ory Hydra (JWT) fronting GitHub's MCP server. |
| [access-mcp-role-assertion](./access-mcp-role-assertion/) | Give one agent a single identity and four roles, asserting a different one per MCP call — then watch it get refused a repo no role it can assume permits. The answer to ambient authority. Warden + Ory Hydra (JWT) fronting GitHub's MCP server. |
| [access-mcp-grade-rest-api](./access-mcp-grade-rest-api/) | Use a plain REST API as efficiently as an MCP server — no GitHub MCP server in the middle. One identity, four fine-grained roles over the GitHub REST API driven by `gh api`, each with a tool-sized role-scoped skill (all sharing one base recipe), plus a forbidden role. Warden + Ory Hydra (JWT) fronting the GitHub REST API. |
| [access-delegation-openbao](./access-delegation-openbao/) | Let an agent call GitHub **as a specific human** — real delegation, not impersonation — with no long-lived GitHub credential outside the vault, and the vault itself refusing any pairing the human's identity provider never authorized. Warden + OpenBao (transit, JWT/CEL, the OAuth app engine, a templated policy) + Keycloak, fronting GitHub's MCP server. |

_More tutorials are on the way._

## License

[Mozilla Public License 2.0](./LICENSE).
