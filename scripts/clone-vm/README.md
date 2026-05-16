# clone-vm/

Pre-Proxmox helpers from when guests ran under libvirt/KVM on a workstation.
Kept because they still work for libvirt hosts and show where the provisioning
model started.

- `clone-vm.sh <source-vm> [new-vm]` clones a libvirt domain with
  `virt-clone` (which assigns a fresh MAC) into `$VM_STORAGE_DIR` (default
  `/var/lib/libvirt/images`), boots it and waits for an address.
- `fix-vm-identity.sh` runs inside the clone: regenerates `/etc/machine-id` and
  the SSH host keys, clears Tailscale node state so the clone joins as a new
  device, then reboots.

On the Proxmox host, guest creation moved to `opentofu/` and
`ansible/roles/proxmox_guest`.
