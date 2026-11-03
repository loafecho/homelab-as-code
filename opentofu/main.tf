# main.tf — the guests OpenTofu manages, adopted one per change and merged only
# when the plan shows 0 to destroy (see README.md).
#
# Keep every guest resource and import block in THIS file: the smoke harness
# copies the directory and compares plans, and splitting resources across files
# makes that comparison harder to reason about.

# A throwaway pilot CT that proves create/plan/destroy and the hardware-key
# gate. Off unless TF_VAR_pilot=true, so a normal `fleet plan` never creates it.
resource "proxmox_virtual_environment_container" "pilot" {
  count = var.pilot ? 1 : 0

  node_name   = var.node_name
  vm_id       = var.pilot_vmid
  pool_id     = var.pool_id
  description = "OpenTofu pilot - safe to destroy."
  # No `tags`: PVE checks tag edits against /vms/<id> only, never the pool, so
  # a pool-scoped token gets 403 on create. Keep the token pool-only; the
  # description marks the guest instead.
  unprivileged  = true
  start_on_boot = false
  started       = true

  operating_system {
    template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
    type             = "debian"
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 256
    swap      = 0
  }

  disk {
    datastore_id = "local-lvm"
    size         = 2
  }

  # No network device on purpose: the pilot proves the lifecycle and the key
  # gate, not networking.

  initialization {
    hostname = "tofu-pilot"
  }
}

# worker, CT 102: an existing container adopted as it is. Every field below
# matches the live config, so the import plans as
# "1 to import, 0 to add, 0 to change, 0 to destroy". Rehearsed against a
# recorded replay of the hypervisor's answers: scripts/smoke/fleet-smoke.sh.
import {
  to = proxmox_virtual_environment_container.worker
  id = "hypervisor/102"
}

resource "proxmox_virtual_environment_container" "worker" {
  node_name     = var.node_name
  pool_id       = var.pool_id
  unprivileged  = true
  start_on_boot = false
  started       = false
  tags          = []

  operating_system {
    # An import can't learn the template a guest was made from; this is the
    # Debian 12 template, and ignore_changes keeps it out of plans.
    template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
    type             = "debian"
  }

  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }

  cpu {
    architecture = "amd64"
    cores        = 2
  }

  memory {
    dedicated = 2048
    swap      = 512
  }

  disk {
    datastore_id  = "local-lvm"
    size          = 16
    mount_options = []
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
    # mac_address is left to the provider: it is read back on import and kept,
    # so no hardware address has to live in git.
    # The tap goes through the Proxmox firewall bridge. It filters nothing until
    # /etc/pve/firewall/102.fw exists with enable: 1 and the datacenter firewall
    # is on (ansible/playbooks/apply-firewall.yml).
    firewall = var.nic_firewall
  }

  initialization {
    hostname = "worker"

    dns {
      domain  = "lan"
      servers = [var.dns_server]
    }

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  features {
    nesting = true
    mount   = []
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      operating_system[0].template_file_id,
      pool_id,
      vm_id,
      timeout_start,
    ]
  }
}

# engine, CT 180: a worker container. First job: SearXNG, the web search an
# agent gateway on the control node calls; more jobs later. Created here,
# configured inside by Ansible. Off only in scripts/smoke/fleet-smoke.sh
# (TF_VAR_engine=false), which rehearses the worker import and nothing else.
resource "proxmox_virtual_environment_container" "engine" {
  count = var.engine ? 1 : 0

  node_name = var.node_name
  vm_id     = 180
  # The tofu token is scoped to the pool only.
  pool_id     = var.pool_id
  description = "engine - worker container (SearXNG first). Managed by OpenTofu; configured inside by Ansible."
  # No `tags`: a pool-scoped token gets 403 on tag edits (see pilot above).
  unprivileged  = true
  start_on_boot = true
  started       = true

  operating_system {
    template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
    type             = "debian"
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 4096
    swap      = 512
  }

  disk {
    datastore_id = "local-lvm"
    size         = 32
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
    # Filtered by roles/proxmox_firewall's 180.fw once the datacenter
    # firewall is on (ansible/playbooks/apply-firewall.yml).
    firewall = var.nic_firewall
  }

  initialization {
    hostname = "engine"

    dns {
      domain  = "lan"
      servers = [var.dns_server]
    }

    # Static, outside the router's DHCP pool.
    ip_config {
      ipv4 {
        address = "192.0.2.61/24"
        gateway = "192.0.2.1"
      }
    }

    # The control node's Ansible key for this guest only.
    user_account {
      keys = var.engine_ssh_keys
    }
  }

  # Docker inside an unprivileged CT needs nesting.
  features {
    nesting = true
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      operating_system[0].template_file_id,
      initialization[0].user_account,
    ]
  }
}

output "pilot_vmid" {
  value = one(proxmox_virtual_environment_container.pilot[*].vm_id)
}
