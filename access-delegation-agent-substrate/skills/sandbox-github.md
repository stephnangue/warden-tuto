# GitHub, for the person you act for

## What it does

The `github-tools` role is GitHub's API, through its MCP tools, for the person you
work for. Warden adds that person's identity, and a GitHub credential of its own, to
each call. You hold neither.

## How to use it

The tools are already attached to you as the `github` MCP server. Do not call the
role's `url` yourself: from this sandbox the role is reached only through the local
gateway, which the `github` server already uses.

- `get_me` returns the GitHub account of the person you work for. Its login need not
  be their name; use it as the owner of their repositories.
- `create_repository`, `get_file_contents`, `list_branches`, `create_pull_request` and
  `pull_request_read` do the rest.
- To change files, clone and push with git: see the `github-git` role and its skill.

## Quirks

- Warden decides which repositories the person lets you create and touch, and with
  which settings. A refused call answers `insufficient_permissions` ("Request denied by
  policy"): say so, and do not look for another way.
- Only the tools the person allows are offered.
