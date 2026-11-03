#!/usr/bin/env bash
# capture-listeners.sh — snapshot every modeled guest's listening sockets (plus
# the hypervisor's own) into ansible/roles/proxmox_firewall/files/listeners/
# <vmid>.txt, the input scripts/tests/check-fw-coverage.py compares against the
# rendered rules.
#
# READ-ONLY. Every remote command is `ss`/`netstat`/`kubectl get`: nothing is
# set, started, written or snapshotted on the hypervisor or any guest. Run from
# the control node:
#
#   scripts/capture-listeners.sh            # capture all, print per guest
#   scripts/capture-listeners.sh 115 130    # only these vmids
#
# Output line format (one socket per line, sorted, de-duplicated):
#   <tcp|udp> <bind-address> <port> <process>
# Access paths mirror ansible/inventory/hosts.yml: LXCs via `pct exec` on the
# hypervisor (sshd is off in 901), VMs over their own SSH, the control node locally.
# Helper functions are reached only through run -> capture "$@" dispatch.
# shellcheck disable=SC2317,SC2329
set -euo pipefail

cd "$(dirname "$0")/.."
OUT=ansible/roles/proxmox_firewall/files/listeners
mkdir -p "$OUT"

SS='ss -H -tlnp; ss -H -ulnp'
# Normalise `ss -H -[tu]lnp` lines (Netid omitted) into "<proto> <addr> <port> <proc>".
norm_ss() {
  python3 -c '
import re, sys
proto = None
for line in sys.stdin:
    f = line.split()
    if not f:
        continue
    state = f[0]
    proto = "tcp" if state == "LISTEN" else "udp"
    local = f[3]
    addr, _, port = local.rpartition(":")
    addr = re.sub(r"%\S+$", "", addr).strip("[]")
    m = re.search(r"users:\(\(\"([^\"]+)\"", line)
    proc = (m.group(1) if m else "-").replace(" ", "_")
    print(proto, addr or "*", port, proc)
'
}
# busybox netstat (vault is Alpine, no ss): "tcp 0 0 <local> <foreign> LISTEN"
norm_netstat() {
  awk '$1 ~ /^(tcp|udp)/ { n = split($4, a, ":"); port = a[n]; addr = substr($4, 1, length($4) - length(port) - 1);
       if (addr == "" || addr == "::") addr = "::"; p = ($1 ~ /^tcp/) ? "tcp" : "udp"; print p, addr, port, "-" }'
}

capture() {  # vmid label command...
  local vmid=$1 label=$2; shift 2
  local tmp; tmp=$(mktemp)
  if ! "$@" >"$tmp" 2>/dev/null; then
    echo "capture-listeners: FAILED $vmid ($label)" >&2; rm -f "$tmp"; return 1
  fi
  {
    echo "# listeners: $label (vmid $vmid) — captured $(date -u +%Y-%m-%dT%H:%MZ) by scripts/capture-listeners.sh"
    echo "# <proto> <bind-address> <port> <process>"
    sort -u "$tmp"
  } >"$OUT/$vmid.txt"
  rm -f "$tmp"
  echo "=== $vmid ($label): $(grep -vc '^#' "$OUT/$vmid.txt") sockets"
  grep -v '^#' "$OUT/$vmid.txt"
}

lxc()  { ssh -o BatchMode=yes root@hypervisor "pct exec $1 -- sh -c '$SS'" | norm_ss; }
host() { ssh -o BatchMode=yes root@hypervisor "$SS" | norm_ss; }
vm()   { ssh -o BatchMode=yes "$1" "${2:-}sh -c '$SS'" | norm_ss; }
self() { sudo -n sh -c "$SS" | norm_ss; }
vault_ns() { ssh -o BatchMode=yes vault 'netstat -tln; netstat -uln' | norm_netstat; }
kube() {
  vm admin@192.0.2.130 'sudo -n '
  # Cilium serves NodePorts in eBPF — invisible to ss. List them as sockets so
  # the coverage check sees every port a LAN client could reach on the node.
  kubectl get svc -A --no-headers -o custom-columns=T:.spec.type,P:.spec.ports[*].nodePort,N:.metadata.name 2>/dev/null |
    awk '$1 == "NodePort" || $1 == "LoadBalancer" { n = split($2, a, ","); for (i = 1; i <= n; i++) if (a[i] != "<none>") print "tcp", "*", a[i], "nodeport:" $3 }'
}

want=("$@")
run() { # vmid label fn args...
  if [ ${#want[@]} -eq 0 ] || printf '%s\n' "${want[@]}" | grep -qx "$1"; then capture "$@"; fi
}

rc=0
run host   "hypervisor (Proxmox host)" host       || rc=1
run 100    control                 self          || rc=1
run 101    vault                   vault_ns      || rc=1
run 112    media                   vm media "sudo -n " || rc=1
run 115    teleport                lxc 115       || rc=1
run 130    kube                    kube          || rc=1
run 180    engine                  lxc 180       || rc=1
run 901    email                   lxc 901       || rc=1
exit $rc
