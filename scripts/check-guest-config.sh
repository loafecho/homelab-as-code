#!/usr/bin/env bash
# check-guest-config.sh — the real guest-hardware drift detector.
#
# Why this exists: `ansible-playbook site.yml --check` can NEVER diff guest
# hardware. community.proxmox.proxmox_kvm and community.proxmox.proxmox both
# declare supports_check_mode=False, so every roles/proxmox_guest task is
# SKIPPED in every check run. Check mode is structurally vacuous here; this
# script reads live `qm config` / `pct config` over root SSH on the hypervisor
# and diffs them against the declared fields in inventory host_vars.
#
# Scope is an EXPLICIT ALLOWLIST of declared fields (cores, memory, balloon,
# disk, net0/net1, onboot; plus machine/hostpci0/virtiofs0/virtiofs1/startup/
# tags/scsi1 where declared). PVE-injected fields (meta, vmgenid, smbios1, boot,
# ostype, vga, serial0, ide2, sshkeys, ciuser, cicustom, agent, cpu, scsihw, ...)
# are out of scope BY ALLOWLIST, NOT BY LUCK: only keys a declaration carries are
# read. NIC MAC addresses are stripped from live net0/net1 before comparing, so
# declarations never have to pin them.
#
# Verdict rules:
#   - fields compared: N is printed PER HOST; a host with N = 0 is an ERROR, not
#     a PASS. A zero-field comparison passing silently is the exact false-clean
#     this gate exists to kill.
#   - Bidirectional: every live vmid must resolve to an inventory host or the
#     explicit `unmanaged_vmids` allowlist in group_vars/all.yml, and every
#     declared vmid must exist live.
#   - A failed lookup is an ERROR, never a clean: SSH failure, zero guests
#     parsed, or an empty config all exit non-zero.
#
# Exit codes: 0 = PASS, 1 = DRIFT (named host:field), 2 = ERROR.
#
#   PVE_SSH_TARGET   ssh destination for the hypervisor (default root@hypervisor)
#
# Reachability is NON-MULTIPLEXED by design: ansible.cfg sets ControlPersist=60s,
# so a multiplexed `ssh host true` returns 0 for 60 s after the transport died.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

INVENTORY="${1:-ansible/inventory/hosts.yml}"
PVE_SSH=(ssh -o ControlPath=none -o ControlMaster=no -o BatchMode=yes -o ConnectTimeout=8 "${PVE_SSH_TARGET:-root@hypervisor}")

# --- 1. Declarations, resolved by ansible-inventory (host_vars + group_vars) ---
decl_json="$(ansible-inventory -i "$INVENTORY" --list 2>/dev/null)"
if [ -z "$decl_json" ]; then
  echo "check-guest-config: ERROR — ansible-inventory returned nothing for $INVENTORY" >&2
  exit 2
fi

# --- 2. Live state, one SSH round trip; delimited sections, counted afterwards ---
# shellcheck disable=SC2016  # expanded on the hypervisor, not here
live_dump="$("${PVE_SSH[@]}" '
  for id in $(qm list | awk "NR>1{print \$1}"); do echo "===QM $id==="; qm config "$id"; done
  for id in $(pct list | awk "NR>1{print \$1}"); do echo "===PCT $id==="; pct config "$id"; done
' 2>/dev/null)"
ssh_rc=$?
if [ "$ssh_rc" -ne 0 ] || [ -z "$live_dump" ]; then
  echo "check-guest-config: ERROR — live config fetch failed (ssh rc=$ssh_rc, bytes=${#live_dump})" >&2
  echo "Gate-input ERROR: hypervisor unreachable or returned nothing — NOT a clean fleet." >&2
  exit 2
fi

# --- 3. Compare in python3 (json + text parsing only; no yq needed) ---
DECL_JSON="$decl_json" LIVE_DUMP="$live_dump" python3 <<'PYEOF'
import json, os, re, sys

decl = json.loads(os.environ["DECL_JSON"])
hostvars = decl.get("_meta", {}).get("hostvars", {})

# ---- parse live sections ----
live = {}   # vmid(int) -> {"kind": "QM"|"PCT", "cfg": {key: value}}
cur = None
for line in os.environ["LIVE_DUMP"].splitlines():
    m = re.match(r"^===(QM|PCT) (\d+)===$", line)
    if m:
        cur = int(m.group(2))
        live[cur] = {"kind": m.group(1), "cfg": {}}
        continue
    if cur is not None and ":" in line:
        k, v = line.split(":", 1)
        live[cur]["cfg"][k.strip()] = v.strip()

if not live:
    print("check-guest-config: ERROR — zero live guests parsed (a failed lookup is not a clean state)")
    sys.exit(2)
for vmid, g in live.items():
    if not g["cfg"]:
        print(f"check-guest-config: ERROR — vmid {vmid} returned an EMPTY config")
        sys.exit(2)

# ---- collect declared hosts (guest_vmid set and non-null) ----
declared = {}   # name -> hv
for name, hv in hostvars.items():
    vmid = hv.get("guest_vmid")
    if vmid in (None, "", "None"):
        continue                      # gateway (not built), localhost, the hypervisor
    declared[name] = hv

unmanaged = []
for hv in hostvars.values():          # group_vars/all — present on every host
    if "unmanaged_vmids" in hv:
        unmanaged = [int(x) for x in hv["unmanaged_vmids"]]
        break

MAC_RE = re.compile(r"(=|hwaddr=)[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}")

def strip_mac(cfgval):
    """Drop the MAC from a PVE netN value: 'virtio=<mac>,bridge=..' -> 'virtio,bridge=..',
    'name=eth0,bridge=..,hwaddr=<mac>,ip=..' -> 'name=eth0,bridge=..,ip=..'."""
    if cfgval is None:
        return None
    v = re.sub(r",?hwaddr=[0-9A-Fa-f:]+", "", cfgval)
    return MAC_RE.sub("", v)

def disk_gb(cfgval):
    m = re.search(r"size=(\d+)G", cfgval or "")
    return int(m.group(1)) if m else None

deltas, errors = [], []
compared_hosts = 0

# Allowlisted, declared-only comparison map: host_vars key -> extractor(cfg) -> (live_value, live_repr)
def cmp_fields(hv, kind, cfg):
    fields = []   # (field_name, declared_value, live_value)
    def add(name, dv, lv):
        fields.append((name, dv, lv))
    if "guest_cores" in hv:   add("cores",  int(hv["guest_cores"]),  int(cfg.get("cores", -1)))
    if "guest_memory" in hv:  add("memory", int(hv["guest_memory"]), int(cfg.get("memory", -1)))
    if "guest_balloon" in hv: add("balloon", int(hv["guest_balloon"]), int(cfg.get("balloon", -1)))
    if "guest_disk_gb" in hv:
        lv = disk_gb(cfg.get("scsi0")) if kind == "QM" else disk_gb(cfg.get("rootfs"))
        add("disk_gb", int(hv["guest_disk_gb"]), lv)
    if "guest_scsi1_gb" in hv: add("scsi1_gb", int(hv["guest_scsi1_gb"]), disk_gb(cfg.get("scsi1")))
    if "guest_net0" in hv:    add("net0", hv["guest_net0"], strip_mac(cfg.get("net0")))
    if "guest_net1" in hv:    add("net1", hv["guest_net1"], strip_mac(cfg.get("net1")))
    if "guest_onboot" in hv:  add("onboot", "1" if hv["guest_onboot"] else "0", cfg.get("onboot", "0"))
    for key in ("startup", "machine", "hostpci0", "virtiofs0", "virtiofs1", "tags"):
        if f"guest_{key}" in hv: add(key, hv[f"guest_{key}"], cfg.get(key))
    return fields

for name, hv in sorted(declared.items()):
    vmid = int(hv["guest_vmid"])
    gtype = hv.get("guest_type", "vm")
    if vmid not in live:
        deltas.append((name, "vmid", f"declared vmid {vmid} does not exist live"))
        print(f"host: {name:<10} vmid={vmid}  fields compared: 0  << declared but NOT live")
        continue
    kind = live[vmid]["kind"]
    cfg = live[vmid]["cfg"]
    expect_kind = "QM" if gtype == "vm" else "PCT"
    if kind != expect_kind:
        deltas.append((name, "guest_type", f"declared={gtype} live={'vm' if kind=='QM' else 'lxc'}"))
    fields = cmp_fields(hv, kind, cfg)
    n = len(fields)
    compared_hosts += 1
    print(f"host: {name:<10} vmid={vmid}  fields compared: {n}")
    if n == 0:
        errors.append(f"{name}: fields compared = 0 — declaration contributes no allowlisted fields; "
                      f"a zero-field comparison is an ERROR, not a PASS")
        continue
    for fname, dv, lv in fields:
        if dv != lv:
            deltas.append((name, fname, f"declared={dv!r} live={lv!r}"))

# ---- bidirectional vmid check ----
declared_vmids = {int(hv["guest_vmid"]) for hv in declared.values()}
allow = set(unmanaged)
for vmid in sorted(live):
    if vmid not in declared_vmids and vmid not in allow:
        deltas.append((f"vmid:{vmid}", "unmanaged",
                       f"live guest {vmid} ({live[vmid]['cfg'].get('name', live[vmid]['cfg'].get('hostname','?'))}) "
                       f"is in neither inventory nor unmanaged_vmids"))
stale_allow = allow - set(live)
for vmid in sorted(stale_allow):
    deltas.append((f"vmid:{vmid}", "stale-allowlist", f"unmanaged_vmids lists {vmid} but it does not exist live"))

print(f"hosts compared: {compared_hosts + len(allow & set(live))} "
      f"({compared_hosts} declared, {len(allow & set(live))} allowlisted-unmanaged)")
print(f"live vmids: {len(live)}, inventory+allowlist: {len(declared_vmids & set(live)) + len(allow & set(live))}")

# ---- stray-guest list — REPORT-ONLY ----
# Every live vmid with no inventory host (allowlisted ones included: allowlisting
# is "known about", not "modeled"), so a guest created outside the repo is SEEN. It never touches deltas, errors or the exit
# code: the verdict rules above are unchanged; strays are reported, never deleted
# or imported.
stray = sorted(v for v in live if v not in declared_vmids)
def _gname(v):
    c = live[v]["cfg"]
    return c.get("name", c.get("hostname", "?"))
print(f"unmodeled: {len(stray)} (stray guests, vmids: "
      + (", ".join(f"{v} {_gname(v)}" for v in stray) or "none") + ")")

if errors:
    for e in errors:
        print(f"ERROR {e}")
    print(f"guest-config: ERROR ({len(errors)} zero-field/invalid comparison(s))")
    sys.exit(2)
if deltas:
    for host, field, detail in deltas:
        print(f"DRIFT {host}:{field} — {detail}")
    print(f"guest-config: DRIFT ({len(deltas)} delta(s))")
    sys.exit(1)
print("guest-config: PASS (0 deltas)")
sys.exit(0)
PYEOF
