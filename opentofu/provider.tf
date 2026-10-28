# provider.tf — the pool-scoped API token (tofu@pve!pilot) can only touch the
# pool named in var.pool_id. Its value is never in this repo: scripts/fleet
# decrypts keys/pve-token.age into TF_VAR_pve_api_token for one command.
provider "proxmox" {
  endpoint  = var.pve_endpoint
  api_token = var.pve_api_token
  insecure  = var.pve_insecure
}
