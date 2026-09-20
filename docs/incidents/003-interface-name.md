# 003 — Node loses its address after `apply-config`

**Component:** Talos network configuration
**Status:** Resolved

## Symptom

In maintenance mode the node had an address and was reachable. After applying
the machine config it had none:

```text
IP            (empty)
GW            n/a
CONNECTIVITY  x FAILED

error serving dns request: dial udp 1.1.1.1:53: network is unreachable
```

The Talos network config screen showed `Interface: (none)`.

## Diagnosis

The distinguishing feature is **it worked in maintenance mode and broke after
apply**. That narrows it to the config, because maintenance mode does not use it.

In maintenance mode Talos brings up DHCP on whatever interface it finds. Once a
config is applied it stops guessing and does exactly what the config says. If
the config names an interface that does not exist, nothing is configured at all.

```bash
$ talosctl get links --insecure -n <node>
NODE   ID       TYPE   ...   HARDWARE ADDR        OPER STATE
<node> ens18    ether        --:--:11:--:17:--    up
<node> bond0    bond         --:--:76:--:44:--    down
<node> dummy0   dummy        --:--:64:--:e1:--    down
```

The interface is `ens18`. The config said `eth0`.

## Root cause

`eth0` was carried over from a generic example. Modern Linux uses predictable
interface names derived from bus topology, and on a Proxmox VM with a VirtIO
NIC that is `ens18`. The name is not wrong in general — it is wrong here.

## Fix

```yaml
    networkInterfaces:
      - interface: ens18
        dhcp: true
        vip:
          ip: <vip>
```

Regenerate and reapply. Nodes that had already installed with the broken config
had to have their disks recreated, since they were unreachable over the API.

## Better fix

Select by attribute rather than by name, the same way disks are selected:

```yaml
    networkInterfaces:
      - deviceSelector:
          physical: true
        dhcp: true
```

This survives a hardware change or a kernel that names things differently. The
config stops encoding an assumption about the machine.

## Prevention

Check before applying, not after:

```bash
talosctl get links --insecure -n <node>
```

Maintenance mode exists partly for this — it is the window in which the machine
can be inspected before it commits to a configuration.
