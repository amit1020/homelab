# Quick reference

Smaller issues that did not warrant a full post-mortem, grouped by layer.

## Proxmox

| Symptom | Cause | Fix |
|---|---|---|
| `no efidisk configured! Using temporary efivars disk.` | EFI disk missing after being deleted during the Secure Boot fix | `qm set <id> --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0` |
| No `Full Clone` option in the clone dialog | Linked clones only exist for templates; a plain VM can only be fully cloned | Nothing — expected behaviour |
| Clone fails outright | VM is running | `qm stop` first |
| VM stops booting after replacing an ISO | The ISO was deleted while the VM held a reference to it; a new file with the same name does not reconnect | Reattach explicitly. Download new images under a versioned filename instead |
| Boot order tries the empty disk first | `boot: order=scsi0;ide2` | `qm set <id> --boot order='ide2;scsi0'` |
| VLAN tag or MAC address disappears | `qm set --net0` **replaces the whole line**; unlisted parameters are deleted | Restate every parameter, or use the web UI, which edits fields |
| `Talos is already installed to disk but booted from another media` | A previous install exists; Talos refuses to overwrite it | Recreate the data disk — nothing on it before `bootstrap` |

## MikroTik

| Symptom | Cause | Fix |
|---|---|---|
| Static leases registered but never used | Leases created on the wrong DHCP server — each VLAN has its own | `/ip/dhcp-server/lease/set [find comment=x] server=<vlan-server>` |
| Lease shows `waiting` / `never` | The lease exists but no machine has requested it; the old dynamic lease is still held | `/ip/dhcp-server/lease/remove [find dynamic=yes]` |
| `already have static lease with this IP` | The target address is taken by another lease | Reassign starting from the **last** entry, so each move frees an address for the next |
| SSH refused despite a correct firewall rule | Two independent checks: the firewall **and** the service's own address restriction | `/ip/service/set ssh address=<cidr>` |
| WireGuard peer's handshake is hours old | Connecting from inside the home network (no hairpin NAT), a changed endpoint, or `AllowedIPs` missing the target network | Add the destination network to `AllowedIPs`; use DDNS for the endpoint |

## Talos

| Symptom | Cause | Fix |
|---|---|---|
| `no disks matched the expression` | The disk is smaller than the selector requires | `talosctl get disks --insecure -n <node>` to see actual sizes; resize or relax the selector |
| Several `talosconfig` contexts (`homelab`, `homelab-1`, ...) | `config merge` never overwrites — it appends with a suffix. Older contexts hold invalid certificates | `rm ~/.talos/config` and merge once |
| `unknown flag: --insecure` on `reset` | Destructive operations always require authentication | Clear the disk from the hypervisor instead |
| `unknown command "<ip>"` | Flags placed before the subcommand | `talosctl get disks --insecure -n <ip>` — subcommand first |
| `"X" "v1alpha1": not registered` | talhelper predates the Talos version and does not know the newer config documents | Use the older `machine:` / `cluster:` schema |
| `is already set in v1alpha1 config` | talhelper generates that document itself from `talconfig.yaml` | Remove it from the patch. `grep "^kind:" clusterconfig/*.yaml` lists what it manages |
| `validate` passes but `apply-config` fails | `validate` checks against the **local** client's schema, not the node's version | Align the image version with the config |

## Tooling and Git

| Symptom | Cause | Fix |
|---|---|---|
| `SOPS decryption failed: 0 successful groups` | `SOPS_AGE_KEY_FILE` unset — recurs in every new terminal | Add the export to `~/.zshrc` |
| `no identity matched any of the recipients` | The file was encrypted with a different key | Compare `grep "public key"` in the key file against `grep recipient` in the encrypted file |
| `kubectl` hits `127.0.0.1:58800` | Active context is Docker Desktop, not the cluster | `kubectl config use-context <cluster>`; merge the kubeconfig so it persists |
| `helm repo add` fails to resolve a hostname | WireGuard routing all traffic through a DNS server that does not answer external queries | Narrow `AllowedIPs` to the networks that need the tunnel |
| The pre-commit hook blocks its own commit | The hook and the README contain the literal string it searches for | Tighten the pattern to full key length: `AGE-SECRET-KEY-1[A-Z0-9]{50,}` |
| `git reset HEAD` fails in a fresh repo | No commits yet, so `HEAD` does not exist | `git rm --cached <file>` |
| YAML parse errors after pasting | Indentation lost in transit. In YAML indentation is syntax, not formatting | `yq eval-all '.' <file> > /dev/null` after every paste |
| `zsh: command not found: --set` | A missing trailing `\` truncated a multi-line command | Keep long invocations in a values file instead |

---

## The one worth repeating

**False positives are a security failure, not an inconvenience.** The
pre-commit hook blocking its own commit was fixable in a minute, but a tool that
cries wolf gets bypassed with `--no-verify` by the third time — and then it
protects nothing. Fixing the pattern was the right response; suppressing the
check was not.
