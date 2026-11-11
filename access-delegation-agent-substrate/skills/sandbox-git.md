# git on GitHub, for the person you act for

## What it does

The `github-git` role is git (clone, fetch, push) on GitHub for the person you work
for. Warden adds that person's identity, and a GitHub credential of its own, to each
request. You hold neither.

## How to use it

Clone through the local gateway, never github.com, and never the role's `url`:

```bash
git clone http://127.0.0.1:8081/git/<owner>/<repo>.git
```

`<owner>` is the account the `github` MCP server's `get_me` returns. Fetch, pull and
push reuse the clone's remote. Commits already carry your author name.

## Quirks

- A refused clone or push answers HTTP 403 `permission denied`: Warden decided the
  person does not allow it. Say so, and do not try another remote.
- Each prompt starts from an empty `~/work`: clone again in every run.
