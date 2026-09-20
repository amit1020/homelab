# 001 — Node falls through to PXE boot

**Component:** Proxmox / UEFI
**Status:** Resolved

## Symptom

The VM never reaches the Talos installer. The console shows:

```text
BdsDxe: failed to load Boot0003 "UEFI QEMU QEMU HARDDISK": Not Found
BdsDxe: loading Boot0002 "UEFI QEMU QEMU DVD-ROM"
BdsDxe: failed to load Boot0002 "UEFI QEMU QEMU DVD-ROM": Access Denied
>>Start PXE over IPv4.
```

## Diagnosis

`Not Found` on the hard disk is expected — it is empty. The signal is
**`Access Denied` on the DVD-ROM**: the firmware found the image and refused to
load it.

That distinction matters. A missing or corrupt ISO produces `Not Found`. A
refusal means the image was located but rejected, which points at signature
verification rather than at the image itself.

## Root cause

Proxmox enables Secure Boot by default when it creates an EFI disk, by
pre-enrolling Microsoft's keys. The stock Talos image is not signed with a
certificate in that chain, so UEFI declines to execute it and falls through to
the next boot device.

## Fix

The `pre-enrolled-keys` flag is only settable at creation time — Proxmox does
not allow editing an existing EFI disk, which is why double-clicking it in the
UI does nothing. The disk has to be recreated:

```bash
qm stop 100
qm set 100 --delete efidisk0
qm set 100 --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0
qm start 100
```

In the web UI: Hardware → select EFI Disk → Detach → Remove → Add → EFI Disk →
**uncheck Pre-Enroll keys**.

The EFI disk holds only boot variables. Recreating it loses nothing.

## Prevention

Set it when the VM is created. In the create wizard, the checkbox appears on
the System tab immediately after selecting OVMF.

```bash
qm create 100 \
  --bios ovmf \
  --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0 \
  ...
```

## Related

A later incident ([004](004-stale-certificates.md)) was caused by deleting the
EFI disk during this fix and not restoring it on every node. The warning
`no efidisk configured! Using temporary efivars disk.` in `qm start` output is
the tell.
