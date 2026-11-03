variable "pve_endpoint" {
  description = "Proxmox API URL, e.g. https://hypervisor.example.com:8006/"
  type        = string
}

variable "pve_api_token" {
  description = "tofu@pve!pilot=<secret>, decrypted at run time by scripts/fleet; never committed (TF_VAR_pve_api_token)"
  type        = string
  sensitive   = true
}

variable "pve_insecure" {
  description = "Skip TLS verification of the Proxmox API. Must stay false: the API token rides this connection. Trust the PVE CA through SSL_CERT_FILE instead (scripts/fleet pins keys/pve-root-ca.pem)"
  type        = bool
  default     = false

  validation {
    condition     = var.pve_insecure == false
    error_message = "pve_insecure = true would send the Proxmox API token to an unverified peer. Pin the PVE CA (SSL_CERT_FILE) instead."
  }
}

variable "node_name" {
  description = "Proxmox node name"
  type        = string
  default     = "hypervisor"
}

variable "pool_id" {
  description = "Resource pool the token is scoped to; every managed guest lives in it"
  type        = string
  default     = "pilot"
}

variable "dns_server" {
  description = "DNS server handed to managed containers"
  type        = string
  default     = "192.0.2.1"
}

variable "pilot" {
  description = "Create the throwaway pilot CT. Off by default."
  type        = bool
  default     = false
}

variable "pilot_vmid" {
  description = "vmid for the pilot LXC; pick one outside every live range"
  type        = number
  default     = 980
}

variable "engine" {
  description = "Create engine (CT 180). On by default; only scripts/smoke/fleet-smoke.sh turns it off."
  type        = bool
  default     = true
}

variable "engine_ssh_keys" {
  description = "SSH public keys baked into engine at create time (the control node's Ansible key for this guest)"
  type        = list(string)
  default     = []
}

# Put the managed containers' network taps on the Proxmox firewall bridge.
# true is what the hypervisor runs (recorded in scripts/smoke/replay/), and
# scripts/smoke/fleet-smoke.sh's check N plans this default against that replay
# and requires "No changes.".
variable "nic_firewall" {
  description = "Set firewall=1 on the managed guests' network interfaces"
  type        = bool
  default     = true
}
