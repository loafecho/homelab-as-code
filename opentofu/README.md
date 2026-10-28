# opentofu/

OpenTofu owns each Proxmox guest's **existence and shape** (vmid, CPU, memory,
disks, NICs, pool). What runs *inside* a guest is the Ansible side
(`../ansible`). Guests are adopted one at a time with an `import` block, and a
change is only merged when its plan shows **0 to destroy**.

| Path | What |
|---|---|
| `versions.tf` | OpenTofu >= 1.10, `bpg/proxmox` pinned exactly, state + plan encryption through an external key provider |
| `provider.tf`, `variables.tf` | API endpoint and a pool-scoped token (never in git) |
| `main.tf` | the managed guests: `worker` (CT 102, imported) and an optional throwaway `pilot` CT |
| `scripts/fleet` | `fleet init / plan / apply / state` with one YubiKey unlock per command |
| `scripts/lib/unlock.sh` | YubiKey helpers: PIN-tries guard, one unwrap per run, token decrypt |
| `scripts/age-key-provider.sh` | OpenTofu `external` key provider: unwraps the state key; no key → tofu refuses |
| `scripts/new-state-key.sh` | one-time: mint and wrap the state key |
| `scripts/smoke/` | rehearsal of the import against a fake Proxmox API, plus controls proving each check can fail |
| `keys/` | layout of the wrapped keys (`keys/README.md`); nothing real is committed |

## Why encrypted state behind a hardware key

State and saved plans are encrypted with OpenTofu's `encryption` block
(`aes_gcm`). The data key is age-wrapped to a YubiKey and an offline paper key,
and `scripts/age-key-provider.sh` unwraps it at run time. With the YubiKey
unplugged the provider fails and tofu refuses to read or write state. The
YubiKey lives on a small deploy box, not on the machine that runs automation.

`fleet apply` only applies a saved, reviewed `fleet.tfplan`; it refuses to run
without one. The token and the unwrapped key reach tofu through the
environment of one command, never the screen or the disk.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # or export TF_VAR_* variables
scripts/fleet init
scripts/fleet plan          # read it
scripts/fleet apply         # applies exactly the saved plan
```

## Tests that run without hardware

```bash
tofu fmt -check -recursive
tofu init -backend=false && tofu validate
bash scripts/smoke/fleet-smoke.sh            # "RESULT: fleet smoke passed"
bash scripts/smoke/fleet-smoke-controls.sh   # "CONTROLS: 8 of 8 caught"
```

`fleet-smoke.sh` copies this directory to a temp dir, stands up
`fake_pve.py` (a TLS Proxmox API stub that replays recorded read-only answers
from `scripts/smoke/replay/worker.json`), swaps the YubiKey for a throwaway age
key, and drives `scripts/fleet` in a pty. It checks that: apply without a plan
is refused before any key use; the first plan is import-only; apply imports
exactly one resource; the second plan is "No changes"; Proxmox saw **zero
writes**; every call carried the token; no token or state key appears in any
output, log or file; and each run asks the key at most twice.
`fleet-smoke-controls.sh` breaks one thing at a time (echo the token, drop the
plan refusal, change memory, use a wrong token, remove a replay answer, ...)
and requires the smoke test to fail for the right reason each time.
