# Kubernetes, for the person you act for

## What it does

The `kube-ops` role is the Kubernetes API for the person you work for, in their own
namespace. Warden adds that person's identity, and a short-lived ServiceAccount token
of its own, to each call. You hold neither.

## How to use it

`kubectl` is already configured to reach the cluster through the local gateway: do not
set a server or a token, and do not call the role's `url`. Always name the namespace;
it has the person's name: `kubectl -n <person> …`.

Read with `get`, `describe`, `logs` and `get events`; change with `patch`, `apply`,
`set` and `rollout`.

## Quirks

- `kubectl exec`, `port-forward` and `attach` do not work: they need an upgraded
  connection, which this sandbox's network refuses. Check your work with
  `rollout status`, pod status, logs, or a short-lived pod that runs `wget` or `curl`
  against the service and exits.
- A call Warden refuses answers `Forbidden`: say so, and do not look for another way.
