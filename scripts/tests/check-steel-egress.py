#!/usr/bin/env python3
"""Regression test: the steel-browser-api egress allow-list stays public-only.

Loads the steel-api-egress CiliumNetworkPolicy and the inventory's lan_cidr and
fails if any toCIDRSet entry, after its excepts, still reaches lan_cidr or any
RFC 1918, CGNAT, link-local or RFC 5737 documentation range. A few public
addresses must stay reachable, so the test cannot pass by emptying the policy.
Offline: reads files only.

  python3 scripts/tests/check-steel-egress.py
"""
import ipaddress
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
NETPOL = ROOT / "kubernetes/workloads/steel-browser/netpol.yaml"
GROUP_VARS = ROOT / "ansible/inventory/group_vars/all.yml"
# (octets..., prefix): RFC 1918, CGNAT, link-local, RFC 5737 documentation
NON_PUBLIC = [(10, 0, 0, 0, 8), (172, 16, 0, 0, 12), (192, 168, 0, 0, 16), (100, 64, 0, 0, 10),
              (169, 254, 0, 0, 16), (192, 0, 2, 0, 24), (198, 51, 100, 0, 24), (203, 0, 113, 0, 24)]
MUST_REACH = ["1.1.1.1", "8.8.8.8", "140.82.112.3", "151.101.1.69"]


def main():
    lan = yaml.safe_load(GROUP_VARS.read_text(encoding="utf-8"))["lan_cidr"]
    forbidden = {ipaddress.ip_network("%d.%d.%d.%d/%d" % n) for n in NON_PUBLIC}
    forbidden = sorted(forbidden | {ipaddress.ip_network(lan)})
    cnp = next(d for d in yaml.safe_load_all(NETPOL.read_text(encoding="utf-8"))
               if d and d.get("kind") == "CiliumNetworkPolicy" and d["metadata"]["name"] == "steel-api-egress")
    entries = [(ipaddress.ip_network(e["cidr"]), [ipaddress.ip_network(x) for x in e.get("except", [])])
               for rule in cnp["spec"]["egress"] for e in rule.get("toCIDRSet", [])]
    if not entries:
        print("check-steel-egress: FAIL (no toCIDRSet entries found)")
        sys.exit(1)

    problems = []
    for net, excepts in entries:
        for bad in forbidden:
            if not net.overlaps(bad):
                continue
            if net.subnet_of(bad) or not any(bad.subnet_of(e) for e in excepts):
                problems.append(f"{net} (except {[str(e) for e in excepts]}) reaches {bad}")

    def allowed(ip):
        a = ipaddress.ip_address(ip)
        return any(a in n and not any(a in e for e in ex) for n, ex in entries)

    problems += [f"public address {ip} is no longer allowed" for ip in MUST_REACH if not allowed(ip)]
    if problems:
        print("check-steel-egress: FAIL")
        for p in problems:
            print("  " + p)
        sys.exit(1)
    print(f"check-steel-egress: OK ({len(entries)} CIDR entries; none reach lan_cidr {lan} "
          "or a private/CGNAT/link-local/documentation range)")


if __name__ == "__main__":
    main()
