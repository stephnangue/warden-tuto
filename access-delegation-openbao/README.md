# Access delegation for AI agents, on OpenBao

An AI agent calls GitHub MCP tools **as a specific human**, with no long-lived
GitHub credential anywhere outside OpenBao — and OpenBao refuses the request
unless that human's identity provider authorized *that specific agent* to act
for them.

Four decisions happen inside OpenBao on every request:

| | |
|---|---|
| **transit** | holds the signing key for Warden's OIDC issuer; Warden signs by calling `transit/sign/`, and never reads the key |
| **`auth/jwt` + a CEL role** | decides whether to trust the assertion, and as whom |
| **the OAuth app engine** | holds each user's GitHub refresh token, and mints an access token per read |
| **a templated ACL policy** | scopes a login to exactly one user's credential |

Warden is the gateway in front. It authenticates both principals, mints a
short-lived assertion naming both, signs it in OpenBao, logs in with it, and
injects whatever comes back into the outbound request. The agent never receives
a GitHub token.

## What you need

- Docker, `python3`, `curl`
- **[Claude Code](https://docs.claude.com/en/docs/claude-code)** — the MCP client used to drive
  the demo
- A **GitHub OAuth App** — https://github.com/settings/developers — with the
  callback URL `http://127.0.0.1:8765/callback`

Unlike the other tutorials here, this one needs no Warden binary on your `PATH` — Warden runs in
the compose stack, and `setup.py` does the wiring over its API.

```bash
git clone https://github.com/stephnangue/warden-tuto.git
cd warden-tuto/access-delegation-openbao
```

```bash
cp .env.example .env    # fill in GH_CLIENT_ID and GH_CLIENT_SECRET
./up.sh                 # OpenBao, Keycloak, Warden, and the wiring
./enroll.py alice       # one-time browser consent, per user
./mcp-config.sh alice   # prints the .mcp.json block for Claude Code
```

`./down.sh` stops everything and discards all state.

If something already occupies 8200, 8080 or 8400, set `BAO_PORT`,
`KEYCLOAK_PORT` or `WARDEN_PORT` in `.env`.

## Try it

Paste the output of `./mcp-config.sh alice` into your `.mcp.json` and ask Claude
to call `get_me`. It returns **alice's** GitHub identity — the account she
approved during enrollment.

Two refusals are worth running, because they fail at different layers:

```bash
./mcp-config.sh bob     # bob authorized agent-9, not agent-1
```

That request is refused **inside OpenBao**, at login, in the CEL program's own
words:

```
CEL role 'access-delegation' blocked authorization with message:
this user has not authorized this agent to act for them
```

bob's token is perfectly valid and agent-1 is a legitimate agent. Possession of
a valid user token is not enough. Drop the `Authorization` header entirely and
Warden refuses earlier still, with `401` — the spec requires a user principal
and none was presented.

## How the pieces line up

The chain only works because one string matches at both ends:

- Keycloak stamps `may_act.sub = agent-1` on alice's token — the IdP stating
  which agent may act for her (RFC 8693). Keycloak builds nested JSON from
  dotted claim names, so a mapper named `may_act.sub` produces it.
- Warden's user auth role lifts it with `metadata_claims {"/may_act/sub": "authorized_agent"}`.
- The spec projects it into the assertion with `assertion_user_claims=sub,authorized_agent`.
- The CEL program compares `claims.warden_user.authorized_agent == claims.warden_sub`.

`bound_claims` cannot express that comparison — it matches a claim against
*fixed values*, and here the expected value is another claim. That is why this
is a CEL role.

**The enrollment contract.** Warden reads exactly
`github/creds/<what credential_name resolves to>`. `credential_name` is
`{{user.sub}}`, which resolves to the user auth role's `user_claim`
(`preferred_username`). So `./enroll.py alice` must use the same name Keycloak
knows her by. Nothing validates the match until the first real request, which
then fails with `no credentials returned for 'alice' on mount 'github'`.

## Things that will bite you

Found the hard way while building this:

- **`warden server --dev` rejects `-config`.** Dev mode always uses inmem
  storage, and the `signer` stanza only exists in a config file — so Warden runs
  in normal mode here, and `up.sh` initializes it over the API.
- **The published Warden image is distroless**, so there is no shell to
  `docker compose exec` into. `operator init` goes through `PUT /v1/sys/init`.
- **`issuer_url` must be `https://` unless the host is loopback.** The issuer
  names itself `http://localhost:8400`, while OpenBao fetches keys from
  `http://warden:8400/oidc/jwks` and matches `bound_issuer` to the former. What
  the issuer calls itself and where its keys are fetched from are two different
  things.
- **Keycloak stamps `iss` from the request host.** Tokens fetched from the host
  say `127.0.0.1:<port>`; Warden reaches Keycloak at `keycloak:8080`. Same split:
  discovery over the internal name, `bound_issuer` matching what tokens say.
- **The API needs `Content-Type: application/json`.** Without it a JSON body is
  silently ignored and you get a config write that appears to succeed and
  changes nothing.
- **Warden answers `501` before `operator init` and `503` while sealed**, so a
  readiness check must wait for a response, not a `2xx`.
- **Both policy types must be in scope.** The capability policy governs the
  path, the MCP policy governs the call, and access is the intersection — an
  MCP mount with no MCP policy attached denies everything.
- **Two transit keys, not one.** Warden derives `<prefix>-<alg>` and its issuer
  is not ready until *both* RS256 and ES256 exist. A signer policy covering only
  one leaves the issuer permanently not-ready with nothing naming the cause.

## Demo posture

Not how to run any of this in production: dev-mode OpenBao with a known root
token, in-memory Warden storage, a static seal key on disk, Keycloak in dev
mode, plain HTTP, and a password grant standing in for a browser login. The
shapes are real; the postures are not.

## The equivalent commands

`setup.py` does the wiring over the API because the payloads nest and bash
quoting was a losing battle. By hand it is:

```bash
# OpenBao: the signer policy (the wildcard covers both algs)
bao policy write warden-signer - <<'EOF'
path "transit/keys/warden-issuer-key-*"        { capabilities = ["create", "read", "update"] }
path "transit/keys/warden-issuer-key-*/rotate" { capabilities = ["update"] }
path "transit/sign/warden-issuer-key-*"        { capabilities = ["update"] }
EOF

# OpenBao: trust Warden's issuer
bao write auth/jwt/config \
    jwks_url=http://warden:8400/oidc/jwks \
    bound_issuer=http://localhost:8400 \
    jwt_supported_algs=RS256

# OpenBao: the templated policy, keyed on the alias NAME
bao policy write github-delegated - <<EOF
path "github/creds/{{identity.entity.aliases.$ACCESSOR.name}}" {
  capabilities = ["read"]
}
EOF

# Warden: a keyless source that logs in at OpenBao's CEL endpoint
warden cred source create bao -type=hvault \
  -config=vault_address=http://openbao:8200 \
  -config=auth_method=oidc_federation \
  -config=jwt_mount=jwt/cel \
  -config=jwt_role=access-delegation \
  -config=audience=openbao-demo
```

`jwt_mount=jwt/cel` composes to `auth/jwt/cel/login`, which is where OpenBao's
CEL roles authenticate. That works because Warden does not validate the mount
string and both endpoints take the same `{role, jwt}` payload — it is emergent
rather than a designed integration, and it is pinned to these versions:
OpenBao 2.6.2, the OAuth app plugin v3.4.0, Warden v0.20.0.
