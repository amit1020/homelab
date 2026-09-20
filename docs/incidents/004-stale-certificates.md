# 004 — `certificate signed by unknown authority`

**Component:** Talos PKI
**Status:** Resolved

## Symptom

Network is fine, the node answers `ping`, but every authenticated call fails:

```text
transport: authentication handshake failed: tls: failed to verify certificate:
x509: certificate signed by unknown authority
```

## Diagnosis

The question is whether the bad certificate is on the client or the node. One
command separates them — bypass the merged client config entirely and use the
freshly generated one:

```bash
talosctl --talosconfig ./clusterconfig/talosconfig -n <node> version
```

- **Works** → the client config is stale. See [006](006-flux-wrong-repo.md) for
  the same class of problem, and check `talosctl config contexts`.
- **Fails too** → the node holds certificates that do not match the current
  secrets.

Here it failed too.

## Root cause

An earlier install had written Talos to disk, creating a `STATE` partition with
its own identity derived from a previous `talsecret`. Recreating the VM's data
disk did not remove it, so the node came back up presenting certificates signed
by a CA that no longer existed.

The node was also reporting `Talos is already installed to disk but booted from
another media` — the same underlying condition, seen from a different angle.

## Fix

`talosctl reset` is not available here: it is a destructive operation and
therefore always requires authentication, which is exactly what is broken.

```bash
$ talosctl reset --insecure -n <node>
unknown flag: --insecure
```

So the disk is cleared from the hypervisor instead:

```bash
qm stop 100
qm set 100 --scsi0 local-lvm:60,discard=on,ssd=1
qm start 100
```

This creates a new empty disk. Before `bootstrap` there is nothing on it —
no etcd, no workloads, no cluster PKI.

The node's network identity is unaffected: the MAC address lives in the VM
definition and the DHCP reservation lives on the router. Neither is on the disk.

## Prevention

Regenerating cluster secrets invalidates every node. If `talsecret.sops.yaml` is
recreated, every node must be wiped and reconfigured — there is no partial path.

Once `bootstrap` has run this becomes expensive, which is the argument for
backing up the age key and the secrets file before that point rather than after.
