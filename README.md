# Homelab — Talos Kubernetes Cluster

A five-node Kubernetes cluster running on Talos Linux, fully declared in this
repository. Every piece of cluster state lives in Git: machine configuration,
network layout, workloads, and encrypted secrets. The cluster can be destroyed
and rebuilt from this repo alone.

---

## Architecture

```text
Internet
   |
   +-- ASUS router ............ 192.---.---.0/24   home network
          |
          +-- MikroTik (RouterOS 7) ...... routing, DHCP, firewall
                 |
                 +-- bridge ........ 192.168.---.0/24   MikroTik LAN
                 +-- vlan99-secure . 192.168.---.0/24   cluster network
                 +-- wireguard1 .... ---.---.---.0/24     remote access
```

The cluster lives on an isolated VLAN. Access is over WireGuard only — there is
no route into VLAN 99 from the home network.

### Physical hosts

| Host | Hardware | Runs |
|---|---|---|
| `brain` | 16 cores / 32 GB | 3 control plane nodes |
| `worker` | i5-13500 / 64 GB | 2 worker nodes |

### Cluster nodes

| Node | Role | Address | vCPU / RAM / Disk |
|---|---|---|---|
| `cp-1` | control plane | 192.168.--.21 | 4 / 8 GB / 60 GB |
| `cp-2` | control plane | 192.168.--.22 | 4 / 8 GB / 60 GB |
| `cp-3` | control plane | 192.168.--.23 | 4 / 8 GB / 60 GB |
| `worker-1` | worker | 192.168.--.31 | 6 / 24 GB / 200 GB |
| `worker-2` | worker | 192.168.--.32 | 6 / 24 GB / 200 GB |

The Kubernetes API is reachable at `192.168.--.9` — a floating VIP that moves
between control plane nodes via Layer 2 announcements.

---

## Stack

| Layer | Choice | Why |
|---|---|---|
| OS | [Talos Linux](https://www.talos.dev) v1.14 | Immutable, API-driven, no SSH or shell. Entire machine state derives from one config file. |
| Config management | [talhelper](https://github.com/budimanjojo/talhelper) | Declares the whole cluster in a single `talconfig.yaml` with native SOPS support. |
| CNI | [Cilium](https://cilium.io) | eBPF dataplane, full NetworkPolicy, kube-proxy replacement, and L2 load balancing — one component instead of three. |
| GitOps | [Flux](https://fluxcd.io) | Cluster state reconciles from this repo. No manual `kubectl apply`. |
| Secrets | [SOPS](https://github.com/getsops/sops) + age | Encrypted at rest in Git, decrypted in-cluster by Flux. |
| Storage | local-path-provisioner | Both workers share one physical host, so replicated storage would add complexity without adding durability. |

---

## Design decisions

**Three control plane nodes, not one.** etcd needs a quorum. Three nodes allow
rolling upgrades and node failure without cluster downtime. This is not true
HA — all three run on the same physical host — but it exercises the correct
operational patterns. Two control planes would be strictly worse than one:
losing either breaks quorum.

**Cilium over Flannel.** Flannel works out of the box but offers no
NetworkPolicy and no observability. Cilium provides pod-level access control,
Hubble for traffic visibility, and replaces both kube-proxy and MetalLB.

**Isolated VLAN.** The cluster has no route to the home network. Remote access
goes through WireGuard, which keeps the management path and the blast radius
narrow.

**local-path over Longhorn or Ceph.** Replicated storage protects against node
failure. Both workers are VMs on the same physical host, so a host failure
takes out every replica — the replication would cost resources and buy nothing.
This changes when a second physical host is added.

**CEL disk selectors, not device names.** `/dev/sda` is not stable across
reboots. Selecting by attribute means the same config works on any node.

---

## Repository layout

```text
.
├── .githooks/
│   └── pre-commit             Blocks commits containing plaintext secrets
├── .github/workflows/
│   └── security.yaml          Server-side secret scanning
├── docs/
│   └── network-plan.md        IPAM — subnets, allocations, reserved ranges
├── scripts/
│   └── bootstrap.sh           One-command environment setup
├── talos/
│   ├── talconfig.yaml         Cluster definition
│   ├── talsecret.sops.yaml    Cluster PKI (encrypted)
│   ├── schematic-id.txt       Talos Image Factory schematic
│   └── patches/               Layered config patches
│       ├── common.yaml        DNS, NTP, sysctls — all nodes
│       ├── controlplane.yaml  VIP, firewall rules
│       └── worker.yaml        Node labels, kubelet mounts
├── kubernetes/
│   ├── bootstrap/             Cilium, Flux — applied once
│   ├── infrastructure/        Ingress, cert-manager, monitoring
│   └── apps/                  Workloads
├── .sops.yaml                 Encryption rules (public key only)
└── README.md
```

---

## Setup

### Prerequisites

- [Homebrew](https://brew.sh)
- The age private key, restored from backup (never stored in this repo)

### Step 1 — Restore the age key

```bash
mkdir -p ~/.config/sops/age
cp /Volumes/<drive>/homelab/age-key.txt ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

Without this key nothing in the repo can be decrypted, and bootstrap will stop
with an error.

### Step 2 — Bootstrap

```bash
git clone git@github.com:USERNAME/homelab.git
cd homelab
./scripts/bootstrap.sh
```

Expected output:

```text
-- Tooling --
v sops already installed
Installing gitleaks...

-- Git hooks --
v pre-commit hook active

-- SOPS key --
v age key present
v decryption works

v Environment ready
```

The script installs tooling, enables the git hooks, and verifies that the key
decrypts this repo's secrets. It is idempotent — rerunning only fills in what
is missing.

If the script will not run:

```bash
chmod +x scripts/bootstrap.sh .githooks/*
```

### Manual activation

The only strictly required step is enabling the hooks:

```bash
git config core.hooksPath .githooks
chmod +x .githooks/*
git config --get core.hooksPath   # should print: .githooks
```

Then install the tools:

```bash
brew install sops age gitleaks talosctl kubectl helm talhelper
brew install fluxcd/tap/flux
```

---

## Secrets

Secrets are encrypted with SOPS using an age key. The public key is committed
in `.sops.yaml`; the private key never touches this repo.

SOPS encrypts values while leaving structure readable, so a diff shows which
field changed without exposing what it changed to.

### Editing

```bash
sops talos/talsecret.sops.yaml
```

Decrypts in memory, opens your editor, re-encrypts on save. The file is never
written to disk in plaintext.

> **Never run `sops --decrypt --in-place`.** It leaves the file unencrypted on
> disk. A forgotten re-encrypt puts the secret in Git history permanently.

### Creating

```bash
talhelper gensecret > talos/talsecret.sops.yaml
sops --encrypt --in-place talos/talsecret.sops.yaml
head -5 talos/talsecret.sops.yaml   # must show ENC[AES256_GCM
```

Encryption is a one-time operation. Once encrypted the file stays encrypted —
there is no per-commit encryption step.

---

## Pre-commit hook

`.githooks/pre-commit` blocks any commit that fails these checks:

1. Every staged `*.sops.yaml` contains `ENC[AES256_GCM`
2. No `talosconfig`, `kubeconfig`, `keys.txt`, or raw `secrets.yaml` is staged
3. No `AGE-SECRET-KEY-1` or PEM private key appears in the diff
4. `gitleaks protect --staged` passes (skipped with a warning if not installed)

Checks run cheapest-first, so an obvious failure does not wait on a full scan.

### Verifying it works

```bash
echo "AGE-SECRET-KEY-1TESTTESTTEST" > test-leak.txt
git add test-leak.txt
git commit -m "test"
```

The commit should be blocked. Clean up:

```bash
git reset HEAD test-leak.txt && rm test-leak.txt
```

If it went through, re-run `git config core.hooksPath .githooks`.

To override deliberately: `git commit --no-verify`. Never on a file containing
secrets — the Actions workflow catches it server-side, but only after it is
already in history.

---

## Defense in depth

| Layer | When | What it does | Cost of a miss |
|---|---|---|---|
| `sops <file>` for edits | While working | File is never plaintext on disk | None |
| pre-commit hook | Before commit | **Blocks** the commit | Seconds |
| GitHub push protection | On push | Blocks known token formats | A minute |
| GitHub Actions | After push | Alerts and records | Rotate keys, rebuild |

Earlier layers are cheaper. By the time Actions fires, the secret is already
in history.

---

## Operations

### Applying config changes

```bash
cd talos
talhelper genconfig
talosctl apply-config -n 192.168.---.21 -f clusterconfig/homelab-cp-1.yaml
```

Use `--mode try --timeout 3m` for anything that could cut off access — firewall
rules, addressing, routing. The node rolls back automatically if you lose
contact.

### Upgrading

```bash
# Talos — one node at a time, workers first
talosctl -n 192.168.---.31 upgrade \
  --image factory.talos.dev/metal-installer/$(cat talos/schematic-id.txt):v1.14.1
talosctl -n 192.168.---.21 health

# Kubernetes — separate operation
talosctl -n 192.168.---.21 upgrade-k8s --to 1.36.4
```

Never skip a minor version. Never upgrade without the schematic ID — doing so
silently strips all system extensions.

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
talosctl --talosconfig backup.talosconfig -n 192.168.---.21 \
  etcd snapshot etcd-$(date +%F).snapshot
```

Losing the age key is unrecoverable.

---

## Status

- [x] Network design and IPAM
- [x] VM provisioning on Proxmox
- [x] Secrets management and pre-commit tooling
- [ ] Talos cluster bootstrap
- [ ] Cilium
- [ ] Storage
- [ ] Flux GitOps
- [ ] Monitoring

## Roadmap

- NetworkPolicy enforcement across namespaces
- BGP peering with MikroTik in place of L2 announcements
- Renovate for automated dependency updates
- Trivy Operator for image scanning
- NFS-backed storage once a NAS is added