#!/usr/bin/env bash
# test-fw-rollback.sh — offline checks for scripts/fw-rollback.sh (dry-run only, no root).
#
#   scripts/tests/test-fw-rollback.sh [path/to/fw-rollback.sh]
#
# Proves the 2026-11-01 incident fixes: every rollback path writes the two
# bridge-nf-call sysctls back to 0, arm starts the conntrack watch, and watch
# rolls back at the threshold and not below it. Exits 1 on the first failure.
# CI also runs it against a copy without the sysctl reset (the 2026-11-01 failure)
# and expects it to fail (control).
set -uo pipefail

script=${1:-scripts/fw-rollback.sh}
fx=$(mktemp -d)
trap 'rm -rf "$fx"' EXIT
fail=0

check() {  # check NAME EXPECTED-REGEX OUTPUT [absent]
  local name=$1 re=$2 out=$3 mode=${4:-present}
  if grep -Eq -- "$re" <<<"$out"; then found=1; else found=0; fi
  if { [ "$mode" = present ] && [ "$found" -eq 1 ]; } || { [ "$mode" = absent ] && [ "$found" -eq 0 ]; }; then
    echo "ok   $name"
  else
    echo "FAIL $name (expected /$re/ $mode)"; fail=1
    while IFS= read -r line; do echo "     | $line"; done <<<"$out"
  fi
}

ct() { printf '%s\n' "$1" >"$fx/nf_conntrack_count"; printf '%s\n' "$2" >"$fx/nf_conntrack_max"; }
sysctl_re='^\+ sysctl -w net\.bridge\.bridge-nf-call-iptables=0 net\.bridge\.bridge-nf-call-ip6tables=0$'

out=$(bash "$script" --dry-run now 2>&1)
check "now: datacenter firewall off" '^\+ pvesh set /cluster/firewall/options --enable 0$' "$out"
check "now: bridge sysctls back to 0" "$sysctl_re" "$out"

out=$(bash "$script" --dry-run arm 10 2>&1)
check "arm: dead-man timer" '^\+ systemd-run --unit fw-deadman --on-active=10m .* now$' "$out"
check "arm: conntrack watch timer" '^\+ systemd-run --unit fw-ctwatch --on-active=10s --on-unit-active=10s .* watch$' "$out"

out=$(bash "$script" --dry-run disarm 2>&1)
check "disarm: stops both timers" '^\+ systemctl stop fw-deadman\.timer fw-ctwatch\.timer$' "$out"

ct 1400 262144
out=$(FW_CT_DIR=$fx bash "$script" --dry-run watch 2>&1)
check "watch 0.5%: ok" '< 50%, ok$' "$out"
check "watch 0.5%: no rollback" '^\+ pvesh' "$out" absent

ct 131071 262144
out=$(FW_CT_DIR=$fx bash "$script" --dry-run watch 2>&1)
check "watch just under 50%: no rollback" '^\+ pvesh' "$out" absent

ct 131072 262144
out=$(FW_CT_DIR=$fx bash "$script" --dry-run watch 2>&1)
check "watch at 50%: rolls back" '^\+ pvesh set /cluster/firewall/options --enable 0$' "$out"
check "watch at 50%: bridge sysctls back to 0" "$sysctl_re" "$out"

ct 262144 262144
out=$(FW_CT_DIR=$fx FW_CT_PCT=90 bash "$script" --dry-run watch 2>&1)
check "watch full, FW_CT_PCT=90: rolls back" '^\+ pvesh set' "$out"

ct "" 262144
FW_CT_DIR=$fx bash "$script" --dry-run watch >/dev/null 2>&1; rc=$?
check "watch unreadable count: exits 1" '^1$' "$rc"

exit "$fail"
