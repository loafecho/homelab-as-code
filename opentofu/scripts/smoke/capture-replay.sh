#!/usr/bin/env bash
# capture-replay.sh — record the hypervisor's real API answers about CT 102
# into scripts/smoke/replay/worker.json for fake_pve.py to replay. Read-only:
# `pvesh get` as root over SSH, nothing else.
#
# Nothing is simulated: CT 102 is really in pool `pilot`. The replay is
# FILTERED to CT 102: /cluster/resources and pool pilot's members keep only its
# row (engine, CT 180, is in the pool too, but the smoke plans CT 102 alone,
# TF_VAR_engine=false).
# The file lists that under "filtered". Hardware addresses are replaced with
# "@MAC@" (fake_pve.py fills in a per-run value) and the node's TLS fingerprint
# is dropped, so the recording is safe to commit. Re-captured 2026-11-02 after
# the container's NIC was put behind the Proxmox firewall.
#
#   PVE_SSH_TARGET=root@hypervisor bash scripts/smoke/capture-replay.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p replay
ssh "${PVE_SSH_TARGET:-root@hypervisor}" bash -s <<'SH' | python3 -c '
import datetime, json, re, sys
get = {}
for line in sys.stdin:
    if line.strip():
        path, body = line.rstrip("\n").split("\t", 1)
        get[path] = json.loads(body)
rows = [r for r in get["/cluster/resources?type=vm"] if r.get("vmid") == 102]
assert len(rows) == 1 and rows[0].get("pool") == "pilot", "CT 102 missing, or not in pool pilot"
get["/cluster/resources?type=vm"] = rows
only102 = lambda ms: [m for m in ms if m.get("vmid") == 102]
assert len(only102(get["/pools/pilot"]["members"])) == 1, "CT 102 is not a member of pool pilot"
get["/pools/pilot"]["members"] = only102(get["/pools/pilot"]["members"])
for pool in get["/pools?poolid=pilot"]:
    pool["members"] = only102(pool.get("members", []))
for n in get.get("/nodes", []):
    n.pop("ssl_fingerprint", None)
for k, v in get.items():
    if k.endswith("/config"):
        for nk in [x for x in v if x.startswith("net")]:
            v[nk] = re.sub(r"hwaddr=[^,]+", "hwaddr=@MAC@", v[nk])
json.dump({
    "captured": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "source": "pvesh get as root on the hypervisor (scripts/smoke/capture-replay.sh)",
    "simulated": [],
    "filtered": ["only CT 102 kept in /cluster/resources, /pools/pilot and /pools?poolid=pilot (the smoke plans CT 102 alone)"],
    "get": get,
}, sys.stdout, indent=1, sort_keys=True)
print()' > replay/worker.json.new
for p in /version /nodes /nodes/hypervisor/lxc/102/config /nodes/hypervisor/lxc/102/status/current \
         /pools /pools/pilot '/pools?poolid=pilot' '/cluster/resources?type=vm' /nodes/hypervisor/storage; do
  path=${p%%\?*}; args=()
  case $p in *\?*) q=${p#*\?}; args=("--${q%%=*}" "${q#*=}") ;; esac
  printf '%s\t' "$p"; pvesh get "$path" "${args[@]}" --output-format json </dev/null; echo
done
SH
mv replay/worker.json.new replay/worker.json
python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print("captured", len(d["get"]), "answers ->", sys.argv[1], "| simulated:", d["simulated"], "| filtered:", *d.get("filtered", []))' replay/worker.json
