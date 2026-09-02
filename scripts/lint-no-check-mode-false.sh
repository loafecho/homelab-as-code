#!/usr/bin/env bash
# Forbid `check_mode: false` anywhere in the Ansible tree.
#
# Why this exists: community.proxmox.proxmox_kvm / .proxmox declare
# supports_check_mode=False, so roles/proxmox_guest tasks SKIP under --check. The
# "obvious fix" once you know that is `check_mode: false`, which turns every
# --check run (including the drift gate) into a LIVE APPLY with state: present,
# update: true. The correct detector is scripts/check-guest-config.sh, which reads
# live qm/pct config instead of pretending check mode works.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../ansible" || exit 2
hits=$(grep -rnE '^[[:space:]]*check_mode:[[:space:]]*(false|no)([[:space:]]|$)' site.yml playbooks/ roles/ 2>/dev/null)
if [ -n "$hits" ]; then
  echo "LINT FAIL — check_mode: false converts --check into a live apply:"
  echo "$hits"
  exit 1
fi
echo "lint-no-check-mode-false: OK (no check_mode: false in site.yml, playbooks/, roles/)"
