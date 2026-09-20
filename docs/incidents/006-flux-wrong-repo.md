# 006 — Flux pinned to a stale revision forever

**Component:** Flux / GitHub deploy keys
**Status:** Resolved

## Symptom

Flux reports healthy and keeps re-applying the same old commit, no matter how
many times it is reconciled:

```bash
$ flux get sources git
NAME          REVISION             READY   MESSAGE
flux-system   main@sha1:433d45ed   True    stored artifact for revision 'main@sha1:433d45ed'
```

New commits never appear. `kubernetes/flux/` does not exist in the local repo
despite bootstrap reporting that it committed manifests there.

## Diagnosis

`READY: True` is again misleading — it reflects the cached artifact, not a
successful fetch. The events tell the real story:

```bash
$ kubectl describe gitrepository flux-system -n flux-system | tail -20
Warning  GitOperationFailed  failed to checkout and determine revision:
  unable to list remote for 'ssh://git@github.com/<user>/homelab.git':
  repository not found
```

Over SSH, **`repository not found` almost always means no permission**, not that
the repository is absent. GitHub does not distinguish between the two for
unauthenticated requests.

## Root cause

Two mistakes compounding.

First, `flux bootstrap` was run with `--repository=talos-homelab` while the
actual repo was `homelab`. **`flux bootstrap` creates the repository if it does
not exist** — so a second repo appeared, and the manifests were committed there.

Second, the deploy key generated during bootstrap was added to that second repo.
Pointing the `GitRepository` at the correct repo afterwards produced the
permission error, because the key did not cover it. GitHub also refuses to
register the same deploy key on two repositories.

## Fix

Patching the URL alone was not enough — the key still did not match, and a
repeated bootstrap reported "up to date" without correcting anything.

A clean reinstall was the shortest path:

```bash
flux uninstall --silent
rm -rf kubernetes/flux
git add -A && git commit -m "Remove Flux manifests" && git push
```

Then remove any leftover deploy keys from both repos, and bootstrap once with
the correct name:

```bash
read -s GITHUB_TOKEN
export GITHUB_TOKEN
export GITHUB_USER=<user>

flux bootstrap github \
  --owner=$GITHUB_USER \
  --repository=homelab \
  --branch=main \
  --path=kubernetes/flux \
  --personal
```

Verify what it is actually pointed at:

```bash
kubectl get gitrepository flux-system -n flux-system -o jsonpath='{.spec.url}{"\n"}'
```

## Prevention

- Check the URL after bootstrap; do not assume the flag was right.
- `flux bootstrap` is only idempotent against the same target. Against a
  different one it reports success while changing nothing meaningful.
- Read `kubectl describe` events rather than trusting the READY column.

## On the token

The PAT is used once, during bootstrap, to create the deploy key. After that the
cluster authenticates over SSH and the token is never used again — so it should
be deleted immediately.

`read -s` keeps it out of shell history, which `export TOKEN=...` does not.
