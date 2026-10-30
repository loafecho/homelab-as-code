#!/usr/bin/env bash
# lint-pve-tls.sh — static check that the Proxmox API token is only ever sent
# over verified TLS. Fails if:
#   - variables.tf's pve_insecure does not default to false, or lost its
#     validation block;
#   - any .tf / .tfvars* sets insecure or pve_insecure to true;
#   - any script sets TF_VAR_pve_insecure to anything but false;
#   - scripts/fleet stops pinning SSL_CERT_FILE to the PVE CA before tofu runs.
# Offline: reads files only.
#
#   bash scripts/lint-pve-tls.sh   # PASS = "lint-pve-tls: OK ..."
# shellcheck disable=SC2016  # the $ in the grep patterns are meant literally
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
bad=0
no() { echo "LINT FAIL: $*"; bad=1; }

block=$(awk '/^variable "pve_insecure"/,/^}/' variables.tf)
[ -n "$block" ] || no "variables.tf: no pve_insecure variable"
grep -qE '^[[:space:]]*default[[:space:]]*=[[:space:]]*false[[:space:]]*$' <<<"$block" \
  || no "variables.tf: pve_insecure must default to false"
grep -qE 'condition[[:space:]]*=[[:space:]]*var\.pve_insecure[[:space:]]*==[[:space:]]*false' <<<"$block" \
  || no "variables.tf: pve_insecure lost its validation (condition = var.pve_insecure == false)"

hits=$(grep -rnE '^[[:space:]]*(pve_)?insecure[[:space:]]*=[[:space:]]*"?true' \
  --include='*.tf' --include='*.tfvars' --include='*.tfvars.*' . 2>/dev/null)
[ -z "$hits" ] || no "TLS verification switched off: $hits"

hits=$(grep -rnE --exclude=lint-pve-tls.sh 'TF_VAR_pve_insecure=' scripts 2>/dev/null | grep -vE 'TF_VAR_pve_insecure=false([[:space:]]|$)')
[ -z "$hits" ] || no "a script sets TF_VAR_pve_insecure to something other than false: $hits"

ca_line=$(grep -nE '^[[:space:]]*SSL_CERT_FILE=\$\(readlink -f -- "\$pve_ca"\)' scripts/fleet | head -1 | cut -d: -f1)
tofu_line=$(grep -nE '^[[:space:]]*plan\)[[:space:]]+tofu plan' scripts/fleet | head -1 | cut -d: -f1)
if [ -z "$ca_line" ] || [ -z "$tofu_line" ] || [ "$ca_line" -ge "$tofu_line" ]; then
  no "scripts/fleet must set SSL_CERT_FILE to the pinned PVE CA before running tofu plan"
fi
grep -qE '^[[:space:]]*export SSL_CERT_FILE' scripts/fleet || no "scripts/fleet does not export SSL_CERT_FILE"
grep -qE '\[ -s "\$pve_ca" \] \|\| fail' scripts/fleet || no "scripts/fleet no longer refuses a missing PVE CA"

[ "$bad" -eq 0 ] || exit 1
echo "lint-pve-tls: OK (pve_insecure defaults false + validated; fleet pins the PVE CA)"
