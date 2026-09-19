# Homelab — Talos Kubernetes Cluster

A five-node Kubernetes cluster on Talos Linux, fully declared in this
repository. Machine configuration, network layout, workloads and encrypted
secrets all live in Git. The cluster reconciles itself from this repo — and can
be destroyed and rebuilt from it alone.

> Private addresses are redacted throughout this README. The real values live in
> `docs/network-plan.md`, which is not published.

---

## Architecture

```text
Internet
   |
   +-- ASUS router ............ home network, DHCP for the house
          |
          +-- MikroTik (RouterOS 7) ...... routing, DHCP, firewall
                 |
                 +-- bridge ........... MikroTik LAN
                 +-- vlan99-secure .... cluster network  <-- the cluster
                 +-- wireguard1 ....... remote access
```

The cluster sits on an isolated VLAN with no route from the home network.
Every management path — `talosctl`, `kubectl`, the Proxmox UI — goes through
WireGuard.

### Physical hosts

| Host | Hardware | Runs |
|---|---|---|
| `brain` | 16 cores / 32 GB | 3 control plane nodes |
| `worker` | i5-13500 / 64 GB | 2 worker nodes |

### Cluster nodes

| Node | Role | vCPU / RAM / Disk |
|---|---|---|
| `cp-1` `cp-2` `cp-3` | control plane | 4 / 8 GB / 60 GB each |
| `worker-1` `worker-2` | worker | 6 / 24 GB / 200 GB each |

The Kubernetes API answers on a floating VIP that moves between control plane
nodes via Cilium L2 announcements. No external load balancer.

---

## Stack

| Layer | Choice | Why |
|---|---|---|
| OS | [Talos Linux](https://www.talos.dev) v1.14 | Immutable, API-driven. No SSH, no shell, no package manager. The entire machine derives from one config file. |
| Config | [talhelper](https://github.com/budimanjojo/talhelper) | Declares all five nodes in one `talconfig.yaml`, with native SOPS support. |
| CNI | [Cilium](https://cilium.io) 1.17 | eBPF dataplane, NetworkPolicy, kube-proxy replacement and L2 load balancing — one component instead of three. |
| GitOps | [Flux](https://fluxcd.io) v2.9 | The cluster pulls its own state from this repo. No manual `kubectl apply`. |
| Secrets | [SOPS](https://github.com/getsops/sops) + age | Encrypted at rest in Git, decrypted in-cluster by Flux. |
| Storage | local-path-provisioner | Both workers share one physical host, so replication would add cost without adding durability. |

---

## Design decisions

**Three control plane nodes, not one.** etcd needs a quorum. Three allows
rolling upgrades and survives losing one node. This is not real HA — all three
are VMs on the same physical host — but it exercises the correct operational
patterns. Two would be strictly worse than one: losing either breaks quorum.

**Cilium over Flannel.** Flannel works out of the box but has no NetworkPolicy
and no observability. Cilium gives pod-level access control, Hubble for traffic
visibility, and replaces both kube-proxy and MetalLB. On Talos it needs explicit
process capabilities and a manual cgroup root — both are in
`kubernetes/bootstrap/cilium-values.yaml` with comments explaining why.

**GitOps pull, not CI push.** The cluster lives on an isolated VLAN reachable
only over WireGuard, so a CI runner cannot reach it — and shouldn't have to.
Flux runs inside the cluster and pulls from Git, so nothing external holds
cluster credentials and no inbound port is opened. Manual changes are reverted
within the reconciliation interval.

**Isolated VLAN.** No route from the home network. This also means DNS and NTP
need explicit firewall rules — a Talos node will not finish booting without a
synchronized clock, and that dependency is easy to miss.

**local-path over Longhorn or Ceph.** Replicated storage protects against node
failure, but both workers are VMs on the same host — a host failure takes out
every replica. Revisit when a second physical host or a NAS exists.

**Selectors, not names.** Disks are matched by CEL expression rather than
`/dev/sda`, because device names are not stable across reboots. The same lesson
applies to network interfaces: the config names the real interface rather than
assuming `eth0`.

---

## Repository layout

```text
.
├── .githooks/
│   └── pre-commit             Blocks commits containing plaintext secrets
├── .github/workflows/
│   └── security.yaml          Server-side secret scanning
├── docs/
│   ├── network-plan.md        IPAM — subnets, allocations, reserved ranges
│   └── incidents/             Post-mortems for problems hit during the build
├── scripts/
│   └── bootstrap.sh           One-command environment setup
├── talos/
│   ├── talconfig.yaml         Cluster definition — all five nodes
│   ├── talsecret.sops.yaml    Cluster PKI (encrypted)
│   ├── schematic-id.txt       Talos Image Factory schematic
│   └── patches/
│       ├── common.yaml        NTP, sysctls — all nodes
│       ├── controlplane.yaml  Scheduling policy, firewall rules
│       └── worker.yaml        Node labels, kubelet mounts
├── kubernetes/
│   ├── flux/                  Flux's own manifests + Kustomizations
│   ├── bootstrap/             Cilium config and LB pool
│   └── apps/                  Workloads
├── .sops.yaml                 Encryption rules (public key only)
└── README.md
```

### Configuration layering

Talos config is assembled in layers, so a shared setting is changed in one
place and propagates to all five nodes:

```text
base (generated, holds secrets and identity)
  └─ patches/common.yaml        all five nodes
       ├─ patches/controlplane.yaml   cp-1..3 only
       └─ patches/worker.yaml         worker-1..2 only
```

Anything unique to a single node — hostname, address, disk selector — stays in
`talconfig.yaml` itself.

> **Note on talhelper.** The installed version predates Talos 1.14 and does not
> recognise its newer config documents (`KubeNodeConfig`, `ResolverConfig` and
> others). The patches therefore use the older `machine:` / `cluster:` schema,
> which Talos still honours. Some fields are generated by talhelper itself and
> must not be set in a patch — `grep "^kind:" clusterconfig/*.yaml` lists which.

---

## Setup

### Prerequisites

- [Homebrew](https://brew.sh)
- The age private key, restored from backup — it is never stored in this repo

### Step 1 — Restore the age key

```bash
mkdir -p ~/.config/sops/age
cp /Volumes/<drive>/homelab/age-key.txt ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

Without this key nothing in the repo decrypts, and bootstrap stops with an
error.

### Step 2 — Bootstrap the environment

```bash
git clone git@github.com:USERNAME/homelab.git
cd homelab
./scripts/bootstrap.sh
```

The script installs tooling, enables the git hooks, and verifies that the key
decrypts this repo's secrets. It is idempotent — rerunning only fills in what
is missing.

If it will not run: `chmod +x scripts/bootstrap.sh .githooks/*`

### Manual activation

The only strictly required step is enabling the hooks:

```bash
git config core.hooksPath .githooks
chmod +x .githooks/*
git config --get core.hooksPath   # should print: .githooks
```

Then the tools:

```bash
brew install sops age gitleaks talosctl kubectl helm talhelper
brew install fluxcd/tap/flux
```

### Shell environment

Two variables belong in `~/.zshrc`, or SOPS and `kubectl` will fail in any new
terminal:

```bash
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
export KUBECONFIG="$HOME/Documents/homelab/talos/kubeconfig"
```

---

## Secrets

Secrets are encrypted with SOPS using an age key. The public key is committed
in `.sops.yaml`; the private key never touches this repo.

SOPS encrypts values while leaving structure readable, so a diff shows which
field changed without revealing what it changed to.

### Editing

```bash
sops talos/talsecret.sops.yaml
```

Decrypts in memory, opens your editor, re-encrypts on save. The file is never
plaintext on disk.

> **Never run `sops --decrypt --in-place`.** It leaves the file unencrypted on
> disk, and a forgotten re-encrypt puts the secret in Git history permanently.

Encryption is a one-time operation. Once encrypted, the file stays encrypted —
there is no per-commit encryption step.

---

## Defense in depth

| Layer | When | What it does | Cost of a miss |
|---|---|---|---|
| `sops <file>` for edits | While working | File is never plaintext on disk | None |
| pre-commit hook | Before commit | **Blocks** the commit | Seconds |
| GitHub push protection | On push | Blocks known token formats | A minute |
| GitHub Actions | After push | Alerts and records | Rotate keys, rebuild |

Earlier layers are cheaper. By the time Actions fires, the secret is already in
history.

### Pre-commit hook

`.githooks/pre-commit` blocks any commit that fails these checks:

1. Every staged `*.sops.yaml` contains `ENC[AES256_GCM`
2. No `talosconfig`, `kubeconfig`, `keys.txt` or raw `secrets.yaml` is staged
3. No age private key or PEM key appears in the diff
4. `gitleaks protect --staged` passes

Checks run cheapest-first, so an obvious failure does not wait on a full scan.

The third check exists because **gitleaks does not recognise age private keys** —
it scans for known vendor token formats. A tool that covers the common case
still needs supplementing for your own threat model.

---

## Operations

### Day-to-day

```bash
# edit something under kubernetes/
git add . && git commit -m "..." && git push
# Flux applies it within the reconciliation interval
```

`kubectl apply` is reserved for debugging. The repo is the source of truth.

```bash
flux get kustomizations                              # sync status
flux reconcile kustomization infrastructure          # force a sync
flux logs --follow                                   # why something failed
```

### Talos config changes

```bash
cd talos
talhelper genconfig
talosctl validate --config clusterconfig/homelab-cp-1.yaml --mode metal
talosctl apply-config -n <cp-1> -f clusterconfig/homelab-cp-1.yaml
```

Use `--mode try --timeout 3m` for anything that could cut off access — firewall
rules, addressing, routing. The node rolls back on its own if contact is lost.

### Upgrading

```bash
# Talos — one node at a time, workers first
talosctl -n <node> upgrade \
  --image factory.talos.dev/metal-installer/$(cat talos/schematic-id.txt):v1.14.1
talosctl -n <cp-1> health

# Kubernetes — a separate operation
talosctl -n <cp-1> upgrade-k8s --to 1.36.4
```

Never skip a minor version. Never upgrade without the schematic ID — doing so
silently strips every system extension, including the Proxmox guest agent.

### Backups

Two files must exist outside this repo:

| File | Why |
|---|---|
| `~/.config/sops/age/keys.txt` | The only key that decrypts this repo |
| `talos/talsecret.sops.yaml` | Cluster PKI — no node can join without it |

Plus a periodic etcd snapshot, taken with a scoped credential rather than admin
rights:

```bash
talosctl config new backup.talosconfig --roles os:etcd:backup --crt-ttl 8760h
talosctl --talosconfig backup.talosconfig -n <cp-1> \
  etcd snapshot etcd-$(date +%F).snapshot
```

Losing the age key is unrecoverable.

---

## Incidents

`docs/incidents/` documents the problems hit while building this — symptom,
diagnosis and fix for each. A few that cost the most time:

| Problem | Root cause |
|---|---|
| Node stuck at `Booting`, network fine | No DNS on the VLAN, so NTP never resolved, so Talos never finished booting |
| Node lost its address after `apply-config` | Config named `eth0`; the real interface was `ens18` |
| `certificate signed by unknown authority` | Node held certificates from an earlier install |
| Flux reported success, applied nothing | A `kustomization.yaml` in the target directory listed no resources |
| `Access Denied`, fell through to PXE boot | Secure Boot enabled on the Proxmox EFI disk |

Two patterns account for most of them:

**The symptom is rarely where the cause is.** "Port 50000 refused" looked like
an API problem; the root cause was DNS, two layers down. Reading the log first
is faster than guessing.

**Wait before fixing.** Several fixes were applied to machines that were simply
still booting, and each one introduced a new problem — a deleted EFI disk, an
overwritten network line, a duplicate context. Checking uptime costs a second.

---

## Status

- [x] Network design and IPAM
- [x] VM provisioning on Proxmox
- [x] Secrets management and pre-commit tooling
- [x] Talos cluster bootstrap — 5 nodes
- [x] Cilium CNI with L2 load balancing
- [x] Flux GitOps — infrastructure reconciling from Git
- [ ] Storage (local-path)
- [ ] Ingress and cert-manager
- [ ] Monitoring

## Roadmap

- NetworkPolicy enforcement across namespaces
- BGP peering with MikroTik in place of L2 announcements
- Renovate for automated dependency updates
- Trivy Operator for image scanning
- NFS-backed storage once a NAS is added