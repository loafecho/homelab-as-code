#!/usr/bin/env python3
"""Assert the datacenter firewall pins Proxmox's management IPSET.

Proxmox's built-in management rules (8006, 22, 5900-5999, 3128) admit the
"management" IPSET and fall back to local_network (the whole LAN) when it is
missing. This checks a rendered cluster.fw (default: the committed baseline,
which check-renders.sh keeps byte-identical to the render) for:
  - exactly one [IPSET management] section;
  - members == admin_devices IPs + the control-zone guest IP(s), nothing else
    (so no lan_cidr, no subnet, no other guest or the monitor).
Offline: reads files only.

  python3 scripts/tests/check-mgmt-ipset.py [path/to/cluster.fw]
"""
import ipaddress
import pathlib
import sys

import yaml

ANSIBLE_DIR = pathlib.Path(__file__).resolve().parents[2] / "ansible"
GROUP_VARS = ANSIBLE_DIR / "inventory/group_vars/all.yml"
DEFAULT_FW = ANSIBLE_DIR / "roles/proxmox_firewall/files/expected/cluster.fw"


def ipset_members(text, name):
    members, inside, seen = [], False, 0
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if line.startswith("["):
            inside = line.split()[0:2] == ["[IPSET", f"{name}]"]
            seen += inside
            continue
        if inside and line:
            members.append(line)
    return members, seen


def main():
    fw = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_FW
    gv = yaml.safe_load(GROUP_VARS.read_text(encoding="utf-8"))
    want = {d["ip"] for d in gv["admin_devices"]}
    want |= {g["ip"] for g in gv["guests"].values() if g.get("zone") == "control" and g.get("ip")}
    lan = ipaddress.ip_network(gv["lan_cidr"])

    members, seen = ipset_members(fw.read_text(encoding="utf-8"), "management")
    problems = []
    if seen != 1:
        problems.append(f"expected exactly one [IPSET management] section, found {seen}")
    for m in members:
        net = ipaddress.ip_network(m.lstrip("!"), strict=False)
        if net.num_addresses > 1 and net.overlaps(lan):
            problems.append(f"management member {m} is a subnet overlapping lan_cidr {lan}")
    if set(members) != want or len(members) != len(set(members)):
        problems.append(f"management members {sorted(members)} != admin_devices + control {sorted(want)}")
    if problems:
        print(f"check-mgmt-ipset: FAIL ({fw})")
        for p in problems:
            print("  " + p)
        sys.exit(1)
    print(f"check-mgmt-ipset: OK ({len(members)} members: admin_devices + control only)")


if __name__ == "__main__":
    main()
