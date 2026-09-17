# The demo IdP

Keycloak stands in for a workforce IdP. In production this is your Okta, Entra,
or Keycloak — the realm here just makes the demo self-contained.

Two things in `warden-demo-realm.json` matter.

## 1. The `may-act-sub` mapper

It lifts alice's `authorized_agent` user attribute into the claim `may_act.sub`.
Keycloak builds nested JSON from dotted claim names, so that produces:

```json
{ "may_act": { "sub": "agent-1" } }
```

which is the RFC 8693 shape. This is the identity provider stating *which agent
may act for her*, on her own token — and it is the only reason the delegation
check downstream can mean anything. An agent that obtains alice's token but is
not the one she authorized fails, because the attestation travels with the token
rather than being asserted by the caller.

An IdP that emits a flat claim instead would be mapped by name rather than by
the JSON Pointer `/may_act/sub`; see `setup.sh`.

## 2. Two audiences

A token minted for the user leg carries `aud: warden-user`; one for the agent
leg carries `aud: warden-agent`. Each Warden auth role pins `bound_audiences`,
so a token issued for one leg is not valid on the other.

## The cast

| | |
|---|---|
| `alice` | authorized `agent-1` — the happy path |
| `bob` | authorized `agent-9` — the refusal, since `agent-1` is not that agent |
| `agent-1` | confidential client, service account, `client_credentials` |

`agent-9` needs no client here: it never authenticates. It exists only as a
string on bob's token that does not match the caller.
