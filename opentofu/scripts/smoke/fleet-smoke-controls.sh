#!/usr/bin/env bash
# fleet-smoke-controls.sh — prove every fleet-smoke.sh check can fail. Each
# control breaks one thing in a throwaway copy of the repo, runs that copy's
# (unchanged) fleet-smoke.sh, and must see it exit non-zero with the expected
# SMOKE FAIL line(s). A mutation that doesn't apply counts as not caught.
#
#   bash scripts/smoke/fleet-smoke-controls.sh   # PASS = "CONTROLS: 11 of 11 caught"
# shellcheck disable=SC2016  # the $VARs in the mutations are meant literally
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/fleet-controls.XXXXXX")
trap 'rm -rf -- "$T"' EXIT
caught=0 total=0

# control NAME FILE OLD NEW EXPECTED-FAIL...  (replaces the first OLD with NEW)
control() {
  local name=$1 file=$2 old=$3 new=$4 c="$T/$1" out rc want miss=0
  shift 4
  total=$((total + 1))
  rsync -a --exclude .git --exclude 'terraform.tfstate*' --exclude '*.tfplan' --exclude '*.log' \
    "$REPO/" "$c/"
  if ! python3 -c '
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
if old not in s: sys.exit(1)
open(p, "w").write(s.replace(old, new, 1))' "$c/$file" "$old" "$new"; then
    echo "CONTROL $name: NOT CAUGHT (the mutation did not apply to $file)"; return
  fi
  out=$(bash "$c/scripts/smoke/fleet-smoke.sh" 2>&1); rc=$?
  for want in "$@"; do
    grep -qF "SMOKE FAIL: $want" <<<"$out" || { miss=1; echo "    missing: SMOKE FAIL: $want"; }
  done
  if [ "$rc" -ne 0 ] && [ "$miss" -eq 0 ]; then
    caught=$((caught + 1))
    echo "CONTROL $name: caught (exit $rc)"
    grep 'SMOKE FAIL' <<<"$out" | sed 's/^/    /'
  else
    echo "CONTROL $name: NOT CAUGHT (exit $rc)"
    grep -E 'SMOKE|RESULT' <<<"$out" | sed 's/^/    /'
  fi
}

control unlock-removed scripts/fleet \
  $'\nunlock_state_key\n' $'\n: # one-time unlock removed\n' \
  "E too many YubiKey unwraps"
control token-echoed scripts/fleet \
  '  unlock_token keys/pve-token.age' '  unlock_token keys/pve-token.age; echo "token: $TF_VAR_pve_api_token"' \
  "F a secret reached"
control token-to-terminal scripts/fleet \
  '  unlock_token keys/pve-token.age' '  unlock_token keys/pve-token.age; echo "$TF_VAR_pve_api_token" >/dev/tty' \
  "F a secret reached"
control key-echoed scripts/fleet \
  $'\nunlock_state_key\n' $'\nunlock_state_key; echo "key: $FLEET_STATE_KEY_B64"\n' \
  "F a secret reached"
control refusal-removed scripts/fleet \
  $'  [ -s fleet.tfplan ] || fail "no saved plan: run \'fleet plan\' first, read it, then \'fleet apply\'"\n' '' \
  "A apply without a saved plan was not refused"
control memory-4096 main.tf \
  'dedicated = 2048' 'dedicated = 4096' \
  "B first plan is not import-only" "C apply did not just import" "W Proxmox got writes" \
  "D second plan is not 'No changes.'"
control wrong-token scripts/fleet \
  '  unlock_token keys/pve-token.age' \
  "  unlock_token keys/pve-token.age; TF_VAR_pve_api_token='tofu@pve!pilot=00000000-0000-0000-0000-000000000000'" \
  "G Proxmox calls without the right token"
control replay-gap scripts/smoke/replay/worker.json \
  '"/nodes/hypervisor/lxc/102/status/current"' '"/removed-by-control"' \
  "R calls missing from the replay"
# TLS must really be verified: trusting the system roots instead of the
# pinned CA must make the fake's self-signed certificate fail the plan.
control ca-not-pinned scripts/fleet \
  'SSL_CERT_FILE=$(readlink -f -- "$pve_ca")' 'SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt' \
  "B first plan is not import-only"

# N: the default config must match the recorded hypervisor (NIC firewall flag on), and nothing else may drift.
control nic-firewall-off variables.tf \
  $'network interfaces"\n  type        = bool\n  default     = true' $'network interfaces"\n  type        = bool\n  default     = false' \
  "N default plan is not 'No changes.'"
control nic-firewall-plus-mtu main.tf \
  '    firewall = var.nic_firewall' $'    firewall = var.nic_firewall\n    mtu      = 1400' \
  "N default plan is not 'No changes.'"

echo "CONTROLS: $caught of $total caught"
[ "$caught" -eq "$total" ]
