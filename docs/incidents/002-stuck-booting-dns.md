# 002 — Node stuck at `Booting`, network apparently fine

**Component:** MikroTik / Talos boot sequence
**Status:** Resolved

## Symptom

The node boots, obtains an address, and answers `ping`. But `talosctl` cannot
connect:

```bash
$ ping <node>
64 bytes from <node>: icmp_seq=0 ttl=63 time=58.3 ms     # fine

$ talosctl get disks --insecure -n <node>
error: connection refused                                 # not fine
```

The console shows `STAGE: Booting` indefinitely, with `CONNECTIVITY: OK`.

## Diagnosis

`connection refused` is the useful part. It means the packet reached the host
and got an explicit "nothing listening here" — not a firewall dropping it
silently, and not a routing failure. The network is fine; the service is not
running.

Which means the node has not finished booting. The log says why:

```text
error serving dns request {"component": "dns-resolve-cache",
  "error": "read udp <node>:32967-><gateway>:53: i/o timeout"}

time query error {"controller": "time.SyncController",
  "server": "time.cloudflare.com",
  "error": "lookup time.cloudflare.com ... server misbehaving"}
```

## Root cause

A chain of three dependencies:

```text
MikroTik not serving DNS to the VLAN
   → time.cloudflare.com cannot be resolved
      → clock never synchronises
         → Talos does not proceed past Booting
            → apid never starts, port 50000 closed
```

Talos blocks on NTP deliberately. etcd relies on synchronised clocks to order
events between members, and TLS certificates are validated against the clock. A
node with a drifting clock creates failures that are far harder to diagnose than
a node that refuses to start.

The VLAN was isolated for security, and that isolation silently removed two
services the nodes need: DNS and outbound reachability for NTP.

## Fix

Serve DNS to the VLAN:

```bash
/ip/dns/set allow-remote-requests=yes
```

Allow port 53 inbound to the router, **before** the default drop rule:

```bash
/ip/firewall/filter add chain=input protocol=udp dst-port=53 \
  src-address=<vlan-cidr> action=accept place-before=13
/ip/firewall/filter add chain=input protocol=tcp dst-port=53 \
  src-address=<vlan-cidr> action=accept place-before=13
```

And confirm the VLAN has outbound NAT:

```bash
/ip/firewall/nat/print
```

## The `place-before` detail

Rule 13 is RouterOS's default `drop all not coming from LAN`. An accept rule
added **after** it is never evaluated — firewall rules are ordered, and the
first match wins.

Without `place-before=13` the rule lands at the end of the list and changes
nothing, while appearing correct in the config.

## Prevention

An isolated VLAN needs explicit rules for every service its hosts depend on,
including ones that feel like infrastructure rather than application traffic.
DNS and NTP are the two that get forgotten.
