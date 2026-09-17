#!/usr/bin/env python3
"""Wires the delegation path. Called by up.sh; safe to re-run.

Four decisions live in OpenBao, and this configures each one:

  1. transit        holds Warden's issuer signing key   (done in up.sh)
  2. jwt/cel/role   decides whether to trust an assertion, and as whom
  3. github/        holds each user's GitHub refresh token
  4. an ACL policy  scopes a login to one user's credential

Python rather than shell purely for the JSON: these payloads nest, and the
quoting in bash was a losing battle. The README shows the equivalent `bao` and
`warden` commands, which is what you would type by hand.
"""

import json
import os
import sys
import urllib.error
import urllib.request

# Load .env so this runs standalone as well as from up.sh.
if os.path.exists(".env"):
    for line in open(".env"):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())

BAO = f"http://127.0.0.1:{os.environ.get('BAO_PORT', '8200')}"
WARDEN = f"http://127.0.0.1:{os.environ.get('WARDEN_PORT', '8400')}"
# Two names for one Keycloak. Warden reaches it over the compose network;
# tokens are fetched from the host, and Keycloak stamps `iss` from whichever
# host the request arrived on. So discovery uses the internal name and
# bound_issuer matches what the tokens actually say.
KEYCLOAK_INTERNAL = "http://keycloak:8080/realms/warden-demo"
KEYCLOAK_ISSUER = (f"http://127.0.0.1:{os.environ.get('KEYCLOAK_PORT', '8080')}"
                   "/realms/warden-demo")
BAO_TOKEN = "root"
WARDEN_TOKEN = open(".state/root.token").read().strip()


def call(base, token_header, token, method, path, payload=None, quiet_errors=()):
    url = f"{base}/v1/{path}"
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header(token_header, token)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            body = r.read().decode()
            return json.loads(body) if body.strip() else {}
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        if any(m in body for m in quiet_errors):
            return {}
        sys.exit(f"\n{method} {path} failed ({e.code}): {body[:400]}\n")


def bao(method, path, payload=None, **kw):
    return call(BAO, "X-Vault-Token", BAO_TOKEN, method, path, payload, **kw)


def warden(method, path, payload=None, **kw):
    return call(WARDEN, "X-Warden-Token", WARDEN_TOKEN, method, path, payload, **kw)


def warden_upsert(path, payload):
    """Re-runnable create: delete first, so edits actually take effect.

    A plain POST 409s on the second run, and swallowing that would silently
    keep the old definition — the worst of both.
    """
    call(WARDEN, "X-Warden-Token", WARDEN_TOKEN, "DELETE", path,
         quiet_errors=("",))
    return warden("POST", path, payload)


def bao_upsert(path, payload):
    call(BAO, "X-Vault-Token", BAO_TOKEN, "DELETE", path, quiet_errors=("",))
    return bao("POST", path, payload)


def say(msg):
    print(f"\n\033[1m==> {msg}\033[0m")


EXISTS = ("already in use", "path is already in use", "existing mount", "already exists")

# --- Warden: two legs, two separate auth mounts ------------------------------
# The agent's token rides X-Warden-Agent-Token; the user's rides
# Authorization: Bearer. Both come from Keycloak, on different clients, and
# each role pins its own audience — so a token minted for one leg is not valid
# on the other.

say("Warden — agent leg (Keycloak, client credentials)")
warden("POST", "sys/auth/agent-jwt", {"type": "jwt"}, quiet_errors=EXISTS)
warden("PUT", "auth/agent-jwt/config", {
    "mode": "oidc",
    "oidc_discovery_url": KEYCLOAK_INTERNAL,
    "bound_issuer": KEYCLOAK_ISSUER,
})
# azp is the client id, so the agent's principal is literally "agent-1" — the
# same string alice's may_act.sub names. That equality is the whole check.
warden_upsert("auth/agent-jwt/role/agent", {
    "user_claim": "azp",
    "bound_audiences": ["warden-agent"],
    # Both policy types must be in scope: the capability policy governs the
    # path, the MCP policy governs the call, and access is the intersection.
    "token_policies": ["github-mcp-access", "github-tools"],
    "cred_spec_name": "github-user",
    "token_ttl": 3600,
})

say("Warden — user leg (Keycloak)")
warden("POST", "sys/auth/user-jwt", {"type": "jwt"}, quiet_errors=EXISTS)
warden("PUT", "auth/user-jwt/config", {
    "mode": "oidc",
    "oidc_discovery_url": KEYCLOAK_INTERNAL,
    "bound_issuer": KEYCLOAK_ISSUER,
})
# user_claim gives the principal — the value {{user.sub}} resolves to, and so
# the name each user must be enrolled under in the OAuth engine.
#
# metadata_claims lifts the RFC 8693 `may_act` attestation off the user's own
# token. Keycloak emits it nested, so the JSON Pointer /may_act/sub reaches it;
# an IdP emitting a flat claim would be mapped by name instead.
warden_upsert("auth/user-jwt/role/user", {
    "user_claim": "preferred_username",
    "bound_audiences": ["warden-user"],
    "metadata_claims": {"/may_act/sub": "authorized_agent"},
    "token_ttl": 3600,
})

# --- OpenBao, decision 2: whether to trust the assertion, and as whom --------

say("OpenBao — JWT auth trusting Warden's issuer")
bao("POST", "sys/auth/jwt", {"type": "jwt"}, quiet_errors=EXISTS)
# Straight at Warden's own origin root. No publisher needed: those exist for
# internet-facing verifiers that cannot reach the issuer.
# bound_issuer matches the name Warden gives itself (loopback, because
# issuer_url must be https for any non-loopback host); jwks_url is where the
# keys are actually reachable from inside the compose network.
bao("PUT", "auth/jwt/config", {
    "jwks_url": "http://warden:8400/oidc/jwks",
    "bound_issuer": "http://localhost:8400",
    "jwt_supported_algs": ["RS256"],
})

say("OpenBao — the CEL role")
# A declarative role cannot express this. bound_claims matches a claim against
# fixed values; here the expected value is *another claim*. The program also
# builds the entity alias — keyed on the USER, so the templated policy below
# scopes per user — and stamps the agent into token metadata for the audit log.
bao_upsert("auth/jwt/cel/role/access-delegation", {
    "bound_audiences": ["openbao-demo"],
    "cel_program": {
        "variables": [
            {"name": "user",
             "expression": "has(claims.warden_user) ? string(claims.warden_user.sub) : ''"},
            {"name": "authorized",
             "expression": "has(claims.warden_user) && has(claims.warden_user.authorized_agent)"
                           " && claims.warden_user.authorized_agent == claims.warden_sub"},
        ],
        "expression":
            "user == '' ? 'assertion carries no delegated user' : "
            "(authorized ? pb.Auth{"
            " policies: ['github-delegated'],"
            " display_name: user,"
            " alias: logical.Alias{name: user},"
            " metadata: {'warden_agent': string(claims.warden_sub),"
            " 'warden_role': string(claims.warden_role)} } "
            ": 'this user has not authorized this agent to act for them')",
    },
})

say("OpenBao — the templated policy")
accessor = bao("GET", "sys/auth")["data"]["jwt/"]["accessor"]
# Keyed on the alias NAME, which the CEL program set to the user. Not on alias
# metadata: that is shared per alias and last-write-wins, so an alias keyed on
# the agent would race between concurrent users.
bao("PUT", "sys/policies/acl/github-delegated", {
    "policy": 'path "github/creds/{{identity.entity.aliases.%s.name}}" '
              '{ capabilities = ["read"] }' % accessor
})

# --- OpenBao, decision 3: the OAuth app engine -------------------------------

say("OpenBao — the OAuth app secret engine")
bao("POST", "sys/mounts/github", {"type": "oauthapp"}, quiet_errors=EXISTS)
bao("PUT", "github/servers/github", {
    "provider": "github",
    "client_id": os.environ["GH_CLIENT_ID"],
    "client_secret": os.environ["GH_CLIENT_SECRET"],
})

# --- Warden: the credential path and the mount -------------------------------

say("Warden — credential source and spec")
# Keyless: the source holds no OpenBao token. It logs in per request with the
# assertion. jwt_mount "jwt/cel" composes to auth/jwt/cel/login, which is where
# OpenBao's CEL roles authenticate.
warden_upsert("sys/cred/sources/bao", {
    "type": "hvault",
    "config": {
        "vault_address": "http://openbao:8200",
        "auth_method": "oidc_federation",
        "jwt_mount": "jwt/cel",
        "jwt_role": "access-delegation",
        "audience": "openbao-demo",
    },
})
# credential_name resolves per request. One map inside Warden feeds both the
# assertion's warden_user claim and this template, so the name a user is
# enrolled under and the alias the policy binds cannot drift.
warden_upsert("sys/cred/specs/github-user", {
    "type": "oauth_bearer_token",
    "source": "bao",
    "min_ttl": 600,
    "max_ttl": 3600,
    "config": {
        "mint_method": "oauth2",
        "subject_token_source": "warden_identity",
        "assertion_user_claims": "sub,authorized_agent",
        "oauth2_mount": "github",
        "credential_name": "{{user.sub}}",
    },
})

say("Warden — the MCP mount")
warden("POST", "sys/providers/github-mcp",
       {"type": "mcp", "description": "GitHub MCP, brokered per user"},
       quiet_errors=EXISTS)
warden("PUT", "github-mcp/config", {
    "mcp_url": "https://api.githubcopilot.com/mcp",
    "auto_auth_path": "auth/agent-jwt/",
    "user_auth_path": "auth/user-jwt/",
    "user_auth_role": "user",
})
warden("POST", "sys/policies/cbp/github-mcp-access", {
    "policy": 'path "github-mcp/role/+/gateway*" {\n'
              '  capabilities = ["create", "read", "update"]\n}'
})
# MCP traffic with no MCP policy in scope is denied, so the mount needs one.
warden("POST", "sys/policies/mcp/github-tools", {
    "policy": 'path "github-mcp/role/+/gateway*" {\n'
              '  methods { allowed = ["initialize", "tools/list", "tools/call"] }\n'
              '  tools   { allowed = ["get_me", "list_issues", "search_repositories"] }\n}'
})

say("Wired.")
