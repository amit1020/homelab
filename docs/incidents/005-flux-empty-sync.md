# 005 — Flux reports success but applies nothing

**Component:** Flux / Kustomize
**Status:** Resolved

## Symptom

The Kustomization is healthy and syncing the right commit, but the objects it
should create do not exist:

```bash
$ flux get kustomizations
NAME             REVISION             READY   MESSAGE
infrastructure   main@sha1:c4d46dc    True    Applied revision: main@sha1:c4d46dc

$ kubectl get ciliumloadbalancerippool
No resources found
```

## Diagnosis

`READY: True` is not evidence that anything was applied — only that the sync ran
without error. Applying nothing successfully is still success.

The inventory shows what actually happened:

```bash
$ kubectl describe kustomization infrastructure -n flux-system | grep -A3 Inventory
Inventory:
  Entries:
```

Empty. And the digest confirms it:

```text
Digest: sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

That is the SHA-256 of an empty input. Flux processed the directory and produced
nothing.

## Root cause

The target directory contained a `kustomization.yaml` that did not list the
manifests.

When Kustomize finds a `kustomization.yaml`, it uses **only** what that file
declares. It does not fall back to "everything in the directory". A file sitting
next to it that is not in `resources:` is invisible.

## Fix

```yaml
# kubernetes/bootstrap/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cilium-lb.yaml
```

```bash
git add -A && git commit -m "Add cilium-lb to kustomization resources" && git push
flux reconcile kustomization infrastructure --with-source
```

Note that `cilium-values.yaml` is deliberately absent — it is a Helm values file,
not a Kubernetes object. Listing it would make the sync fail.

## Prevention

Check the inventory, not the status:

```bash
kubectl describe kustomization <name> -n flux-system | grep -A10 Inventory
```

An empty inventory on a healthy Kustomization always means the path is wrong or
the resources are not declared.

## Note on `--with-source`

`flux reconcile kustomization <name>` re-applies from Flux's cached copy of the
repo. `--with-source` fetches from Git first. When a change has just been pushed,
the second is the one that does what you meant.
