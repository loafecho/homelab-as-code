# role: `proxmox_guest`

One generic role that provisions a Proxmox guest as **either** a QEMU VM **or**
an LXC container, selected by `guest_type`. One role with a selector was chosen
over separate per-type roles so the variable contract stays in one place.

## Variable contract

| Var | Source | Meaning |
|-----|--------|---------|
| `guest_type` | inventory (`vm`\|`lxc`) | Dispatch selector, **required** |
| `guest_name` | `inventory_hostname` | Guest hostname |
| `guest_vmid` | inventory / `guests` map | Proxmox VMID. **Null ⇒ skipped** (gateway) |
| `guest_ip` | `guests[host].ip` | Reserved address |
| `guest_zone` | `guests[host].zone` | Trust zone (informational here) |
| `guest_state` | default `started` | `present`\|`started`\|`stopped`\|`absent` |
| `proxmox_api_*` | **environment** | API host/user/token, **never in git** |
| `guest_cores` / `guest_memory` / `guest_disk_gb` | defaults / host_vars | Hardware |
| `guest_vm_template` | defaults | VM clone source (cloud-init base) |
| `guest_lxc_ostemplate` | defaults | LXC OS template volume |
| `guest_firewall_enabled` | default `true` | Sets `firewall=1` on the NIC tap |

## Dispatch

`tasks/main.yml` asserts `guest_type`, skips null-vmid guests, then includes
`tasks/vm.yml` or `tasks/lxc.yml`.

## Status: foundation

The connection wiring and the variable contract are real and lint-clean. The
heavy provisioning bodies (cloud-init user-data, disk resize, per-guest
identity, LXC features) are marked `TODO`. New guests are created by
OpenTofu (`opentofu/`); this role keeps the Ansible side of the contract.

The `community.proxmox` modules declare `supports_check_mode=False`, so these
tasks are **skipped** under `--check`. Do not "fix" that with
`check_mode: false`: it turns every dry run into a live apply.
`scripts/lint-no-check-mode-false.sh` forbids it, and real hardware drift is
measured by `scripts/check-guest-config.sh` instead.
