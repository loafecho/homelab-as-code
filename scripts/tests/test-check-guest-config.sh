#!/usr/bin/env bash
# test-check-guest-config.sh — exercise scripts/check-guest-config.sh against the
# example inventory with a stubbed `ssh` that replays canned `qm config` /
# `pct config` output. No hypervisor is contacted.
#
# Cases (each must produce its expected exit code):
#   clean      live matches the declarations             -> 0 PASS
#   drift      kube has 4 cores instead of 8             -> 1 DRIFT kube:cores
#   stray      an undeclared, unallowlisted vmid exists  -> 1 DRIFT vmid:<id>:unmanaged
#   missing    a declared guest does not exist live      -> 1 DRIFT media:vmid
#   unreach    ssh fails                                 -> 2 ERROR
#   empty      ssh succeeds but prints nothing           -> 2 ERROR
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT

# MACs are generated at run time so no hardware address lives in the repo; the
# comparator must strip them before comparing net0.
mac() { printf 'BC:24:11:%02X:%02X:%02X' "$((RANDOM % 256))" "$((RANDOM % 256))" "$((RANDOM % 256))"; }

write_clean() {
  cat > "$T/live.txt" <<DUMP
===QM 100===
name: control
cores: 8
memory: 16384
balloon: 0
scsi0: local-lvm:vm-100-disk-0,size=64G
net0: virtio=$(mac),bridge=vmbr0
onboot: 1
startup: order=1
===QM 101===
name: vault
cores: 2
memory: 3072
balloon: 1792
scsi0: local-lvm:vm-101-disk-0,size=16G
net0: virtio=$(mac),bridge=vmbr0
onboot: 1
startup: order=1,up=30
===QM 112===
name: media
cores: 4
memory: 8192
balloon: 8192
scsi0: local-lvm:vm-112-disk-0,size=64G
net0: virtio=$(mac),bridge=vmbr0
onboot: 1
startup: order=3
machine: q35
===QM 120===
name: scratch
cores: 2
memory: 2048
===QM 130===
name: kube
cores: 8
memory: 24576
balloon: 0
scsi0: local-lvm:vm-130-disk-0,size=32G
scsi1: local-lvm:vm-130-disk-1,size=250G
net0: virtio=$(mac),bridge=vmbr0
onboot: 1
===PCT 115===
hostname: teleport
cores: 2
memory: 2048
rootfs: local-lvm:vm-115-disk-0,size=8G
net0: name=eth0,bridge=vmbr0,hwaddr=$(mac),ip=dhcp,type=veth
onboot: 1
DUMP
}

mkdir -p "$T/bin"
cat > "$T/bin/ssh" <<'SH'
#!/usr/bin/env bash
case "${FAKE_SSH_MODE:-ok}" in
  fail)  exit 255 ;;
  empty) exit 0 ;;
  *)     cat "$FAKE_SSH_DUMP" ;;
esac
SH
chmod +x "$T/bin/ssh"

fails=0
run_case() {  # name expected_rc expected_text [mode]
  local name=$1 want=$2 text=$3 mode=${4:-ok} out rc
  out=$(PATH="$T/bin:$PATH" FAKE_SSH_MODE=$mode FAKE_SSH_DUMP="$T/live.txt" \
        "$REPO/scripts/check-guest-config.sh" 2>&1)
  rc=$?
  if [ "$rc" -eq "$want" ] && grep -qF -- "$text" <<<"$out"; then
    echo "ok   $name (exit $rc, saw: $text)"
  else
    echo "FAIL $name: want exit $want with '$text', got exit $rc"
    while IFS= read -r l; do echo "     | $l"; done <<<"$out"
    fails=$((fails + 1))
  fi
}

write_clean
run_case clean 0 "guest-config: PASS (0 deltas)"

write_clean; sed -i '/^name: kube$/,/^===/ s/^cores: 8$/cores: 4/' "$T/live.txt"
run_case drift 1 "DRIFT kube:cores"

write_clean; printf '===QM 199===\nname: surprise\ncores: 1\n' >> "$T/live.txt"
run_case stray 1 "DRIFT vmid:199:unmanaged"

write_clean; sed -i '/^===QM 112===$/,/^===QM 120===$/{/^===QM 120===$/!d}' "$T/live.txt"
run_case missing 1 "DRIFT media:vmid"

run_case unreach 2 "Gate-input ERROR" fail
run_case empty 2 "Gate-input ERROR" empty

# Every per-host line must report a non-zero field count on the clean run.
write_clean
zero=$(PATH="$T/bin:$PATH" FAKE_SSH_DUMP="$T/live.txt" "$REPO/scripts/check-guest-config.sh" \
       | grep -c 'fields compared: 0' || true)
if [ "$zero" -eq 0 ]; then echo "ok   no host compared zero fields"; else echo "FAIL $zero host(s) compared zero fields"; fails=$((fails + 1)); fi

if [ "$fails" -eq 0 ]; then echo "RESULT: check-guest-config tests passed"; else echo "RESULT: $fails failing case(s)"; exit 1; fi
