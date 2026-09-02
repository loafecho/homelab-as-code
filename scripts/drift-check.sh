#!/usr/bin/env bash
# drift-check.sh — the fleet drift gate.
#
#   ./scripts/drift-check.sh            # full gate: check run + renders + guest comparator
#   ./scripts/drift-check.sh -l vault   # extra args pass through to the ansible check run
#                                       # (the guest comparator + render diff always run fleet-wide)
#
# Why three components instead of `ansible-playbook --check`'s exit code, which
# is vacuous twice over:
#   1. --check exits 0 with changed=N, so "changed forever" staging renders
#      (build/ is gitignored and check mode never writes it) could never fail,
#      and neither could real drift.
#   2. community.proxmox.proxmox_kvm and .proxmox declare
#      supports_check_mode=False, so every roles/proxmox_guest task SKIPS in
#      every check run: no guest hardware is ever diffed.
#
# The verdict has THREE states, because an outage reading as CLEAN is the exact
# failure this gate exists to close:
#   Gate PASSED                            exit 0
#   Gate DRIFT (<host>:<field>)            exit 1  — a result, not a failure:
#                                                    reconcile the declaration, never auto-apply
#   Gate ERROR (unreachable=N failed=N)    exit 2  — the gate could not measure;
#                                                    NOT a clean fleet
#
# Components:
#   a. ansible-playbook site.yml --check --diff — rc matters only via the RECAP's
#      failed/unreachable counts (plus a missing-RECAP guard: a run that produced
#      no RECAP measured nothing and is an ERROR).
#   b. Staging renders, materialized FOR REAL (localhost-only playbooks that touch
#      no live host: render-firewall, validate-tailscale-acl, render-caddy), then
#      diffed against committed references:
#        build/firewall  vs roles/proxmox_firewall/files/expected/
#        build/caddy     vs roles/vault_caddy_tls/files/expected/
#        build/tailscale/acl.hujson vs roles/tailscale_acl/files/acl.hujson
#      A missing reference dir is announced as `SKIPPED (no committed reference)`
#      in the verdict, never a silent pass. A stale reference reads as false
#      DRIFT, not false clean: the safe direction.
#   c. scripts/check-guest-config.sh — the real guest-hardware comparator (live
#      qm/pct config over non-multiplexed SSH vs the declared-field allowlist).
#
# SECRETS
#   The Proxmox API token must already be in the environment, injected by your
#   secrets manager for this one command (e.g. `infisical run -- ...`):
#     PROXMOX_API_TOKEN_ID, PROXMOX_API_TOKEN_SECRET  (PROXMOX_API_USER optional)
#   The values are passed to ansible-playbook as per-command environment only and
#   are never echoed or written to disk. Failures name variables, never values.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
REPO=$PWD

for v in PROXMOX_API_TOKEN_ID PROXMOX_API_TOKEN_SECRET; do
  if [ -z "${!v:+set}" ]; then
    echo "drift-check: $v is not set — inject the Proxmox API token from your secrets manager." >&2
    echo "Gate ERROR (unreachable=? failed=? — no API credential; nothing was measured)"
    exit 2
  fi
done

cd "$REPO/ansible" || exit 2

# ---------------------------------------------------------------------------
# a. Ansible check run. Per-command env only — nothing exported.
# ---------------------------------------------------------------------------
recap_file="$(mktemp)"
trap 'rm -f "$recap_file"' EXIT

PROXMOX_API_USER="${PROXMOX_API_USER:-automation@pve}" \
  ansible-playbook site.yml --check --diff "$@" 2>&1 | tee "$recap_file"
play_rc=${PIPESTATUS[0]}

unreach=$(grep -Eo 'unreachable=[0-9]+' "$recap_file" | awk -F= '{s+=$2} END{print s+0}')
failed=$(grep -Eo ' failed=[0-9]+' "$recap_file" | awk -F= '{s+=$2} END{print s+0}')
have_recap=$(grep -c 'PLAY RECAP' "$recap_file")

# ---------------------------------------------------------------------------
# b. Materialize the staging renders FOR REAL (localhost-only; no live host is
#    touched) and diff against committed references. Check mode never writes
#    build/, so without this the renders "report changed forever" and prove
#    nothing.
# ---------------------------------------------------------------------------
render_err=0
for pb in playbooks/render-firewall.yml playbooks/validate-tailscale-acl.yml playbooks/render-caddy.yml; do
  if ! ansible-playbook "$pb" >/dev/null 2>&1; then
    echo "drift-check: render playbook FAILED: $pb" >&2
    render_err=1
  fi
done

render_drift=()
render_skipped=()

diff_dir() {  # expected_dir build_dir label
  if [ ! -d "$1" ]; then render_skipped+=("$3"); return; fi
  local d
  # -x README.md: provenance notes live beside the baselines, not in the render.
  d=$(diff -ru -x README.md "$1" "$2" 2>&1)
  if [ -n "$d" ]; then
    echo "--- render drift: $3 (expected=$1 vs rendered=$2)"
    echo "$d"
    render_drift+=("render:$3")
  fi
}
diff_dir roles/proxmox_firewall/files/expected build/firewall  firewall
diff_dir roles/vault_caddy_tls/files/expected  build/caddy     caddy
# The staged ACL is a byte copy of its committed source — the source is the reference.
if ! diff -u roles/tailscale_acl/files/acl.hujson build/tailscale/acl.hujson; then
  render_drift+=("render:tailscale")
fi

# ---------------------------------------------------------------------------
# c. The real guest-hardware comparator (always fleet-wide).
# ---------------------------------------------------------------------------
echo
echo "--- guest hardware comparator (scripts/check-guest-config.sh) ---"
gc_out=$("$REPO/scripts/check-guest-config.sh" 2>&1)
gc_rc=$?
echo "$gc_out"

first_drift=$(printf '%s\n' "$gc_out" | grep -m1 '^DRIFT ' | sed -E 's/^DRIFT ([^ ]+) .*/\1/')
[ -z "$first_drift" ] && [ "${#render_drift[@]}" -gt 0 ] && first_drift="${render_drift[0]}"

skip_note=""
[ "${#render_skipped[@]}" -gt 0 ] && skip_note="; render diff: SKIPPED (no committed reference: ${render_skipped[*]})"

# ---------------------------------------------------------------------------
# Verdict — exactly three states.
# ---------------------------------------------------------------------------
echo
if [ "$have_recap" -eq 0 ] || [ "$unreach" -gt 0 ] || [ "$failed" -gt 0 ] || [ "$gc_rc" -eq 2 ] || [ "$render_err" -ne 0 ]; then
  extra=""
  [ "$have_recap" -eq 0 ] && extra="; no PLAY RECAP — the check run measured nothing (play rc=$play_rc)"
  [ "$gc_rc" -eq 2 ] && extra="$extra; guest comparator ERROR"
  [ "$render_err" -ne 0 ] && extra="$extra; render playbook failed"
  echo "Gate ERROR (unreachable=$unreach failed=$failed$extra$skip_note)"
  echo "An ERROR is NOT a clean fleet — the gate could not measure. Fix the path, re-run."
  exit 2
elif [ "$gc_rc" -eq 1 ] || [ "${#render_drift[@]}" -gt 0 ]; then
  echo "Gate DRIFT ($first_drift$skip_note)"
  echo "Drift is a result, not a failure — reconcile the declaration. Never auto-apply,"
  echo "never silence, never widen an allowlist to make this green."
  exit 1
else
  echo "Gate PASSED$skip_note"
  exit 0
fi
