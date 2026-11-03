#!/usr/bin/env bash
# fw-rollback.sh — dead-man's switch for a live Proxmox firewall change.
#
# Runs ON the hypervisor (the Proxmox host), as root, from its console or SSH. The
# rollback is ONE master switch: datacenter firewall enable=0, then a
# pve-firewall stop/start so the rules are flushed now instead of on the next
# ~10 s compile, then the two bridge-netfilter sysctls back to 0.
#
#   fw-rollback.sh --dry-run [arm MIN|disarm|now|watch]   print the exact commands, run nothing
#   fw-rollback.sh arm 10      snapshot /etc/pve/firewall, roll back in 10 min unless
#                              disarmed, and start the conntrack watch (arm BEFORE every live step)
#   fw-rollback.sh disarm      cancel the pending rollback and the watch (the step was verified)
#   fw-rollback.sh now         roll back immediately
#   fw-rollback.sh watch       roll back now if conntrack is at or over FW_CT_PCT (default 50)
#                              percent of nf_conntrack_max; while armed a timer runs this every 10 s
#   fw-rollback.sh status      firewall status, bridge sysctls, conntrack use, pending timers
#
# Install it first:  scp scripts/fw-rollback.sh root@hypervisor:/usr/local/sbin/
#
# Why the sysctls (2026-11-01 incident): enabling the firewall makes PVE write
# net.bridge.bridge-nf-call-iptables/ip6tables=1, so every bridged guest<->guest
# packet goes through conntrack. Disabling it never writes them back (PVE ships 0
# in /usr/lib/sysctl.d/10-pve.conf). A load test filled the 262,144-entry table
# and the hypervisor dropped new packets for every guest, with the firewall already off.
set -euo pipefail

UNIT=fw-deadman
WATCH_UNIT=fw-ctwatch
SELF=/usr/local/sbin/fw-rollback.sh
BACKUP_DIR=/root/fw-backups
CT_DIR=${FW_CT_DIR:-/proc/sys/net/netfilter}
CT_PCT=${FW_CT_PCT:-50}
DRY=0

run() {  # print the command exactly as it will run, then run it (unless --dry-run)
  printf '+ %s\n' "$*"
  [ "$DRY" -eq 1 ] || "$@"
}

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

rollback() {
  run pvesh set /cluster/firewall/options --enable 0
  run pve-firewall stop
  run pve-firewall start
  run sysctl -w net.bridge.bridge-nf-call-iptables=0 net.bridge.bridge-nf-call-ip6tables=0
  run pve-firewall status
  # Whichever of the dead-man or the watch fired, the armed window is over.
  run systemctl stop "$UNIT.timer" "$WATCH_UNIT.timer" || true
}

if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi
cmd=${1:-}
[ -n "$cmd" ] || usage

case "$cmd" in
  now)
    rollback
    ;;
  watch)
    count=$(cat "$CT_DIR/nf_conntrack_count")
    max=$(cat "$CT_DIR/nf_conntrack_max")
    if ! [[ "$count" =~ ^[0-9]+$ && "$max" =~ ^[1-9][0-9]*$ ]]; then
      echo "watch: unreadable conntrack count/max in $CT_DIR" >&2; exit 1
    fi
    if [ $(( count * 100 )) -ge $(( max * CT_PCT )) ]; then
      echo "watch: conntrack $count/$max >= ${CT_PCT}%, rolling back"
      rollback
    else
      echo "watch: conntrack $count/$max < ${CT_PCT}%, ok"
    fi
    ;;
  arm)
    min=${2:-}
    if ! [[ "$min" =~ ^[0-9]+$ ]] || [ "$min" -lt 1 ]; then
      echo "arm needs a whole number of minutes >= 1" >&2; exit 2
    fi
    [ "$DRY" -eq 1 ] || [ -x "$SELF" ] || { echo "install this script at $SELF first" >&2; exit 1; }
    ts=$(date +%Y%m%d-%H%M%S)
    run mkdir -p "$BACKUP_DIR"
    run tar -C /etc/pve -czf "$BACKUP_DIR/firewall-$ts.tgz" firewall
    run systemd-run --unit "$UNIT" --on-active="${min}m" --timer-property=AccuracySec=1s "$SELF" now
    run systemd-run --unit "$WATCH_UNIT" --on-active=10s --on-unit-active=10s \
      --timer-property=AccuracySec=1s --setenv=FW_CT_PCT="$CT_PCT" "$SELF" watch
    echo "armed: firewall rolls back in ${min} min, or as soon as conntrack reaches ${CT_PCT}%,"
    echo "unless you run: $SELF disarm"
    ;;
  disarm)
    run systemctl stop "$UNIT.timer" "$WATCH_UNIT.timer"
    echo "disarmed: no rollback pending, conntrack watch stopped"
    ;;
  status)
    pve-firewall status || true
    sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables || true
    echo "conntrack: $(cat "$CT_DIR/nf_conntrack_count")/$(cat "$CT_DIR/nf_conntrack_max")"
    systemctl list-timers --all --no-pager "$UNIT.timer" "$WATCH_UNIT.timer" || true
    ;;
  *)
    usage
    ;;
esac
