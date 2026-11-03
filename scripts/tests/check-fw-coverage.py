#!/usr/bin/env python3
"""Prove the rendered firewall cuts no live LAN service.

Inputs (all committed, so this runs offline in CI):
  ansible/roles/proxmox_firewall/files/listeners/<vmid>.txt   live sockets, from
      scripts/capture-listeners.sh (`host.txt` is the hypervisor itself)
  ansible/roles/proxmox_firewall/files/listeners/closed.yml   intentionally closed ports
  <fw-dir>/<vmid>.fw + <fw-dir>/cluster.fw            rendered rules (default:
      the committed baseline, which check-renders.sh keeps equal to the render)

For every LAN-reachable listener (bound to a wildcard or a LAN address — not
loopback, tailnet 100.64/10 / fd7a:115c:a1e0::/48 or link-local unicast), one of
these must hold, else FAIL:
  - an enabled `IN ACCEPT ... -p <proto> -dport <port>` in the guest's .fw
    (cluster.fw [RULES] for the host);
  - a Proxmox built-in: DHCP client replies (udp 68/546, unless the .fw sets
    `dhcp: 0`), or on the host the management-IPSET rules (tcp 22, 8006, 3128,
    5900-5999) when cluster.fw defines [IPSET management];
  - an entry in closed.yml.
It also fails if any rendered `-source`/`-dest` IP is not a known address
(admin device, guest, deploy box, monitoring source, DNS server, lan_cidr) —
so a rule for a dead host (e.g. a decommissioned client) cannot hide in a render.

  python3 scripts/tests/check-fw-coverage.py [--fw-dir DIR]
Prints COVERAGE OK <n>/<n> and exits 0, or COVERAGE FAIL <ok>/<n> and exits 1.
"""
import argparse
import ipaddress
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2] / "ansible"
LISTENERS = ROOT / "roles/proxmox_firewall/files/listeners"
DEFAULT_FW = ROOT / "roles/proxmox_firewall/files/expected"
GROUP_VARS = ROOT / "inventory/group_vars/all.yml"

NOT_LAN = [ipaddress.ip_network(n) for n in (
    "127.0.0.0/8", "::1/128", "fd7a:115c:a1e0::/48", "fe80::/10", "169.254.0.0/16")]
WILDCARD = {"*", "0.0.0.0", "::"}
RULE = re.compile(r"^IN ACCEPT\b(?P<body>.*?)-p (?P<proto>\w+) -dport (?P<port>[\d:,-]+)")


def lan_reachable(addr):
    if addr in WILDCARD:
        return True
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return True  # unknown form: treat as reachable (fail safe)
    # RFC 6598 shared address space (100.64/10), where Tailscale assigns tailnet
    # IPv4 addresses, is the one IPv4 range that is neither private nor global.
    if ip.version == 4 and not ip.is_private and not ip.is_global:
        return False
    return not any(ip in n for n in NOT_LAN)


def port_in(spec, port):
    for part in str(spec).replace(":", "-").split(","):
        lo, _, hi = part.partition("-")
        if int(lo) <= port <= int(hi or lo):
            return True
    return False


def parse_fw(path):
    """Return (allowed [(proto, portspec)], options dict, ipsets set, text)."""
    text = path.read_text(encoding="utf-8")
    allowed, opts, ipsets, section = [], {}, set(), None
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            section = line.strip("[]").split()
            if section[0] == "IPSET":
                ipsets.add(section[1])
            continue
        if section == ["OPTIONS"] and ":" in line:
            k, v = (x.strip() for x in line.split(":", 1))
            opts[k] = v
        elif section == ["RULES"]:
            m = RULE.match(line)
            if m:
                allowed.append((m["proto"], m["port"]))
    return allowed, opts, ipsets, text


def known_ips(gv):
    ips = {d["ip"] for d in gv["admin_devices"]}
    ips |= {g["ip"] for g in gv["guests"].values() if g.get("ip")}
    ips.add(gv["deploy_box"]["ip"])
    ips |= {m["ip"] for m in gv.get("monitoring_sources", [])}
    ips |= {d["ip"] for d in gv.get("dns_servers", [])}
    ips.add(gv["lan_cidr"])
    return ips


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fw-dir", type=pathlib.Path, default=DEFAULT_FW)
    args = ap.parse_args()

    gv = yaml.safe_load(GROUP_VARS.read_text(encoding="utf-8"))
    closed = yaml.safe_load((LISTENERS / "closed.yml").read_text(encoding="utf-8"))["closed"]
    problems, results = [], []

    files = sorted(LISTENERS.glob("*.txt"))
    if not files:
        print("COVERAGE FAIL 0/0 (no listener captures found)")
        sys.exit(1)
    for lf in files:
        vmid = lf.stem
        fw = args.fw_dir / ("cluster.fw" if vmid == "host" else f"{vmid}.fw")
        if not fw.exists():
            problems.append(f"{vmid}: listeners captured but no rendered {fw.name}")
            continue
        allowed, opts, ipsets, _ = parse_fw(fw)
        seen = {}
        for line in lf.read_text(encoding="utf-8").splitlines():
            if not line.strip() or line.startswith("#"):
                continue
            proto, addr, port, proc = line.split()[:4]
            if lan_reachable(addr):
                seen.setdefault((proto, int(port)), set()).add(proc)
        print(f"--- {vmid} ({fw.name}): {len(seen)} LAN listeners")
        for (proto, port), procs in sorted(seen.items()):
            why = None
            if any(p == proto and port_in(spec, port) for p, spec in allowed):
                why = "allowed"
            elif vmid != "host" and proto == "udp" and port in (68, 546) and opts.get("dhcp", "1") != "0":
                why = "builtin dhcp"
            elif vmid == "host" and "management" in ipsets and proto == "tcp" and (
                    port in (22, 8006, 3128) or 5900 <= port <= 5999):
                why = "builtin management ipset"
            else:
                for c in closed:
                    if str(c["vmid"]) == vmid and c["proto"] == proto and port_in(c["port"], port) and (
                            "process" not in c or procs <= {c["process"]}):
                        why = f"closed: {c['reason']}"
                        break
            mark = "ok  " if why else "FAIL"
            results.append(bool(why))
            print(f"  {mark} {proto}/{port} ({','.join(sorted(procs))}) -> {why or 'NOT allowed and NOT in closed.yml'}")

    # every IP a render names must be a known, live address
    known = known_ips(gv)
    for fw in sorted(args.fw_dir.glob("*.fw")):
        for raw in fw.read_text(encoding="utf-8").splitlines():
            if raw.lstrip().startswith("#"):
                continue
            for ip in re.findall(r"-(?:source|dest) ([0-9a-fA-F.:/]+)", raw):
                if ip not in known:
                    problems.append(f"{fw.name}: rule names unknown/dead address {ip}: {raw.strip()}")

    ok, n = sum(results), len(results)
    for p in problems:
        print("  PROBLEM " + p)
    if ok == n and not problems:
        print(f"COVERAGE OK {ok}/{n}")
        return
    print(f"COVERAGE FAIL {ok}/{n} ({len(problems)} other problem(s))")
    sys.exit(1)


if __name__ == "__main__":
    main()
