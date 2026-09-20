# Network plan

IPAM for the cluster and the networks around it. All addresses are RFC 1918
private space.

> If you prefer not to publish addressing, move this file to `.gitignore` and
> remove the link from the root README.

---

## Topology

```text
Internet
   |
   +-- ASUS router ............ 192.----.---.0/24   home network, DHCP for the house
          |
          +-- MikroTik (RouterOS 7)
                 |
                 +-- bridge ........... 192.168.88.0/24   MikroTik LAN
                 +-- vlan99-secure .... 192.168.99.0/24   cluster  <--
                 +-- wireguard1 ....... ---.---.---.0/24     remote access
```

The MikroTik sits behind the ASUS router, so from its perspective the home
network is WAN. This matters when reading firewall rules: traffic from the house
hits the WAN chain, not the LAN chain.

---

## Subnets

| Network | Interface | Role |
|---|---|---|
| 192.----.---.0/24 | `ether1` (WAN) | Home network, managed by the ASUS router |
| 192.168.88.0/24 | `bridge` | MikroTik LAN |
| **192.168.99.0/24** | **`vlan99-secure`** | **Cluster — isolated** |
| ---.---.---.0/24 | `wireguard1` | Remote access tunnel |

---

## Allocations — VLAN 99

| Address | Host | Notes |
|---|---|---|
| .1 | MikroTik | Gateway and DNS for the VLAN |
| **.9** | **Kubernetes API VIP** | Floating. Belongs to no machine — one control plane node holds it at a time |
| .10 | `brain` | Proxmox host |
| .11 | `worker` | Proxmox host |
| .21 – .23 | `cp-1` … `cp-3` | Control plane nodes |
| .31 – .32 | `worker-1`, `worker-2` | Worker nodes |
| .100 – .199 | DHCP pool | Dynamic |
| .200 – .220 | LoadBalancer pool | Assigned by Cilium L2 announcements |

### WireGuard peers

| Address | Peer |
|---|---|
| ---.---.---.1 | MikroTik |
| ---.---.---.2 | MacBook |
| ---.---.---.3 | Windows laptop |

---

## Kubernetes internal networks

These exist only inside the cluster. They are listed here so the ranges are
documented as taken.

| Range | Purpose |
|---|---|
| 10.244.0.0/16 | Pod CIDR |
| 10.96.0.0/12 | Service CIDR |
| cluster.local | Internal DNS domain |

**Collision check:** none of the four physical networks fall inside either
range, including the WireGuard tunnel at 10.10.10.0/24. The Kubernetes defaults
are safe to use here.

This check matters. A home network on 10.0.0.0/8 would overlap the pod CIDR, and
the symptom — pods unable to reach local services — is hard to trace back to
addressing.

---

## Reserved ranges

| Range | Reserved for | Why |
|---|---|---|
| .1 – .99 | Infrastructure | Static, outside the DHCP pool |
| .100 – .199 | DHCP | Dynamic leases |
| .200 – .220 | Kubernetes services | Must not overlap the DHCP pool, or Cilium and the router can hand out the same address |

---

## Access matrix

| From | To VLAN 99 | Notes |
|---|---|---|
| Home network (---) | **blocked** | Treated as WAN by the MikroTik |
| MikroTik LAN (88) | **blocked** | Explicit forward drop |
| WireGuard (---.---.---.) | allowed | The only management path |
| VLAN 99 → internet | allowed | Required for image pulls, DNS and NTP |

Every management operation — `talosctl`, `kubectl`, the Proxmox UI — goes
through the tunnel.

---

## Services the VLAN depends on

An isolated VLAN silently loses services that feel like infrastructure. These
need explicit rules:

| Service | Rule |
|---|---|
| DNS | `allow-remote-requests=yes` plus an input accept on port 53, placed **before** the default drop |
| NTP | Outbound NAT for the VLAN |

Without both, **a Talos node will not finish booting** — it blocks on clock
synchronisation, which depends on DNS resolution. See
[incident 002](incidents/002-stuck-booting-dns.md).

---

## DHCP reservations

Nodes use DHCP with static reservations rather than static addressing, so the
allocation lives in one place and the node config stays generic.

```bash
/ip/dhcp-server/lease/add address=192.168.99.21 mac-address=<MAC> \
  server=dhcp_vlan99 comment=cp1
```

The `server` field must name the VLAN's own DHCP server. Reservations created
against the wrong server wait forever, because a DHCP request is a broadcast
that does not cross VLAN boundaries — see
[quick-reference](incidents/quick-reference.md).
