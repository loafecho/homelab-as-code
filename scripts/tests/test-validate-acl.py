#!/usr/bin/env python3
"""Regression tests for the Tailscale ACL validator (offline, stdlib only).

The committed policy must pass; each widening below must fail. The first three
are the payloads that used to reach "ACL OK": a duplicated tag:admin src, a
hosts remap and a top-level grants any-to-any rule.

  python3 scripts/tests/test-validate-acl.py   # PASS = "RESULT: validate_acl tests passed"
"""
import copy
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile

ROLE_FILES = pathlib.Path(__file__).resolve().parents[2] / "ansible/roles/tailscale_acl/files"
VALIDATOR = ROLE_FILES / "validate_acl.py"
POLICY = ROLE_FILES / "acl.hujson"

spec = importlib.util.spec_from_file_location("validate_acl", VALIDATOR)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
BASE = mod.load_hujson(str(POLICY))


def run(policy):
    with tempfile.NamedTemporaryFile("w", suffix=".hujson", delete=False) as f:
        json.dump(policy, f)
    try:
        r = subprocess.run([sys.executable, str(VALIDATOR), f.name], capture_output=True, text=True)
    finally:
        pathlib.Path(f.name).unlink()
    return r.returncode, (r.stdout + r.stderr).strip()


def with_rule(rule):
    p = copy.deepcopy(BASE)
    p["acls"].append(rule)
    return p


def with_section(key, value):
    p = copy.deepcopy(BASE)
    p[key] = value
    return p


def admin_dst_dup():
    p = copy.deepcopy(BASE)
    for r in p["acls"]:
        if r["src"] == ["tag:admin"]:
            r["dst"] = r["dst"] + r["dst"][:1]
    return p


MUST_FAIL = {
    "duplicated tag:admin src to *:*": with_rule({"action": "accept", "src": ["tag:admin", "tag:admin"], "dst": ["*:*"]}),
    "hosts remap": with_section("hosts", {"control": "0.0.0.0/0"}),
    "grants any-to-any": with_section("grants", [{"src": ["*"], "dst": ["*"], "ip": ["*"]}]),
    "ssh section": with_section("ssh", [{"action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:self"], "users": ["root"]}]),
    "groups section": with_section("groups", {"group:ops": ["autogroup:admin"]}),
    "autoApprovers section": with_section("autoApprovers", {"exitNode": ["tag:monitor"]}),
    "mixed admin+monitor src": with_rule({"action": "accept", "src": ["tag:admin", "tag:monitor"], "dst": ["*:22"]}),
    "wildcard src": with_rule({"action": "accept", "src": ["*"], "dst": ["*:22"]}),
    "admin dst wider than admin ports": with_rule({"action": "accept", "src": ["tag:admin"], "dst": ["*:*"]}),
    "duplicate dst value": admin_dst_dup(),
    "unknown rule key": with_rule({"action": "accept", "src": ["tag:admin"], "dst": ["*:22"], "users": ["*"]}),
}

fails = 0
rc, out = run(BASE)
if rc == 0 and out.startswith("ACL OK"):
    print("ok   committed policy passes")
else:
    print(f"FAIL committed policy rejected (rc={rc}): {out}")
    fails += 1
for name, policy in MUST_FAIL.items():
    rc, out = run(policy)
    if rc == 1 and "ACL VALIDATION FAILED" in out:
        print(f"ok   rejected: {name}")
    else:
        print(f"FAIL accepted: {name} (rc={rc}): {out}")
        fails += 1

if fails:
    print(f"RESULT: validate_acl tests FAILED ({fails})")
    sys.exit(1)
print(f"RESULT: validate_acl tests passed ({len(MUST_FAIL) + 1} cases)")
