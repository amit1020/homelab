# Incidents

Problems hit while building and operating this cluster, with the diagnosis that
actually found the cause. Kept because the reasoning is more reusable than the
fix — most of these will recur in a different form.

## Post-mortems

| # | Incident | Root cause |
|---|---|---|
| [001](001-secure-boot.md) | Node falls through to PXE boot | Secure Boot enabled on the Proxmox EFI disk |
| [002](002-stuck-booting-dns.md) | Node stuck at `Booting`, network fine | No DNS on the VLAN → NTP never resolved → boot never completed |
| [003](003-interface-name.md) | Node lost its address after `apply-config` | Config named `eth0`; the real interface was `ens18` |
| [004](004-stale-certificates.md) | `certificate signed by unknown authority` | Node held PKI from an earlier install |
| [005](005-flux-empty-sync.md) | Flux reported success but applied nothing | A `kustomization.yaml` in the target directory listed no resources |
| [006](006-flux-wrong-repo.md) | Flux pinned to a stale revision forever | `GitRepository` pointed at a repo the deploy key no longer covered |

[quick-reference.md](quick-reference.md) — the smaller ones, one line each.

---

## Patterns

Six post-mortems, three patterns. These are the part worth remembering.

### The symptom is rarely where the cause is

`connection refused on port 50000` looked like an API problem. The cause was
DNS, two layers down: no DNS meant no NTP, no NTP meant Talos never finished
booting, and an unbooted node has no API.

Reading the log first is faster than reasoning from the symptom.

### Wait before fixing

Several fixes were applied to machines that were simply still booting. Each one
introduced a new problem — a deleted EFI disk, an overwritten network line, a
duplicate client context. The debugging took longer than the original issue.

```bash
qm status <vmid> --verbose | grep -E "cpu|uptime"
```

Zero CPU pressure means genuinely stuck. Under two minutes of uptime means wait.

### Three network errors, three different places

| Error | Where the problem is |
|---|---|
| `connection refused` | Reached the host, nothing listening — **the node** |
| `network is unreachable` | No route — **routing or firewall** |
| `timeout` | Packet swallowed — **a firewall dropping silently** |

They look interchangeable and are not. Telling them apart is the first step of
any network diagnosis.

---

## A note on the tooling

Two of these incidents were caused by tools behaving differently than expected
rather than by anything being broken:

- `qm set --net0` **replaces the whole line.** Any parameter not restated is
  deleted — MAC address, VLAN tag, bridge. The web UI edits fields; the CLI
  replaces lines.
- `flux bootstrap` **creates the repository if it does not exist.** A typo in
  `--repository` produced a second repo, and the cluster then synced from it.

Both are documented behaviour. Both cost an hour.
