# versions.tf — pinned toolchain + state encryption.
#
# The provider is pinned EXACTLY (= 0.118.0): a provider bump is its own change
# with its own reviewed plan.
terraform {
  required_version = ">= 1.10.0" # external key provider landed in OpenTofu 1.10

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "= 0.118.0"
    }
  }

  # State and plan files are encrypted. The data key is age-wrapped to two
  # recipients (a YubiKey and an offline paper backup); scripts/age-key-provider.sh
  # unwraps it, which needs the YubiKey plugged in. YubiKey out -> the script
  # fails -> tofu refuses to read or write state.
  encryption {
    key_provider "external" "age" {
      command = ["./scripts/age-key-provider.sh"]
    }

    method "aes_gcm" "state" {
      keys = key_provider.external.age
    }

    state {
      method   = method.aes_gcm.state
      enforced = true
    }

    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}
