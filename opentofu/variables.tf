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
  description = "Skip TLS verification (the default PVE certificate is self-signed)"
  type        = bool
  default     = true
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
