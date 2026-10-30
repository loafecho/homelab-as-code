#!/usr/bin/env python3
"""
validate_acl.py — offline hujson/policy validator for the Tailscale ACL.

No network access, no tailnet credentials, no `tailscale` CLI login required.
Run against the staged roles/tailscale_acl/files/acl.hujson to prove:
  1. It is well-formed hujson (JSON + // and /* */ comments + trailing commas).
  2. It matches the LOCKED slimmed admin-plane policy: tag:admin gets the
     admin ports, tag:monitor gets exactly one narrow grant to control:443,
     and nothing else grants a broader tailnet service mesh.

Only the tagOwners and acls sections are allowed; any other top-level
section (grants, hosts, ssh, ...) fails, and each rule's src must be exactly
{tag:admin} or {tag:monitor} with no duplicates.

Exit 0 + prints a summary on success. Exit 1 with a reason on any violation.
This is a pure lint/test — it never talks to the Tailscale API and never
mutates the live tailnet ACL.
"""
import json
import re
import sys

ALLOWED_TAGS = {"tag:admin", "tag:monitor"}
ADMIN_PORTS = {"*:22", "*:443", "*:8006"}
# The policy may contain ONLY these top-level sections. Anything else (grants,
# hosts, ssh, groups, autoApprovers, nodeAttrs, postures, ...) can widen access
# without touching tagOwners/acls, so an unknown key is a failure, not a pass.
ALLOWED_TOP_LEVEL = {"tagOwners", "acls"}
ALLOWED_RULE_KEYS = {"action", "src", "dst"}
MONITOR_GRANT = {"src": ["tag:monitor"], "dst": ["control:443"]}


def strip_hujson_comments(text: str) -> str:
    """Strip // line comments and /* */ block comments, respecting strings."""
    out = []
    i, n = 0, len(text)
    in_string = False
    while i < n:
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue
        if c == '"':
            in_string = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j == -1 else j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            if j == -1:
                raise ValueError("unterminated block comment")
            i = j + 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def strip_trailing_commas(text: str) -> str:
    return re.sub(r",(\s*[\]}])", r"\1", text)


def load_hujson(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        raw = f.read()
    no_comments = strip_hujson_comments(raw)
    no_trailing_commas = strip_trailing_commas(no_comments)
    return json.loads(no_trailing_commas)


def fail(msg: str) -> None:
    print(f"ACL VALIDATION FAILED: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: validate_acl.py <path-to-acl.hujson>")

    path = sys.argv[1]
    try:
        policy = load_hujson(path)
    except (ValueError, json.JSONDecodeError) as exc:
        fail(f"not valid hujson/JSON: {exc}")
        return

    # --- structural checks -------------------------------------------------
    if not isinstance(policy, dict):
        fail("policy is not a JSON object")
    unknown_sections = set(policy) - ALLOWED_TOP_LEVEL
    if unknown_sections:
        fail(f"unexpected top-level policy sections (only {sorted(ALLOWED_TOP_LEVEL)} "
             f"are allowed): {sorted(unknown_sections)}")

    tag_owners = policy.get("tagOwners")
    if not isinstance(tag_owners, dict) or not tag_owners:
        fail("tagOwners missing or empty")

    unexpected_tags = set(tag_owners) - ALLOWED_TAGS
    if unexpected_tags:
        fail(f"unexpected tagOwners entries (service-mesh creep?): {sorted(unexpected_tags)}")

    acls = policy.get("acls")
    if not isinstance(acls, list) or not acls:
        fail("acls missing or empty")

    for rule in acls:
        if not isinstance(rule, dict):
            fail(f"acl entry is not an object: {rule!r}")
        if rule.get("action") != "accept":
            fail(f"unexpected action (default should be deny-all elsewhere): {rule!r}")
        if not isinstance(rule.get("src"), list) or not rule["src"]:
            fail(f"acl entry missing src list: {rule!r}")
        if not isinstance(rule.get("dst"), list) or not rule["dst"]:
            fail(f"acl entry missing dst list: {rule!r}")
        unknown_keys = set(rule) - ALLOWED_RULE_KEYS
        if unknown_keys:
            fail(f"acl entry has unexpected keys {sorted(unknown_keys)}: {rule!r}")
        for field in ("src", "dst"):
            if not all(isinstance(v, str) for v in rule[field]):
                fail(f"acl entry {field} must be a list of strings: {rule!r}")
            if len(set(rule[field])) != len(rule[field]):
                fail(f"acl entry has duplicate {field} values: {rule!r}")

    # --- policy-intent checks (this IS the slimmed admin-plane ACL) --------
    # Classify by the SET of sources: every rule must be exactly an admin rule
    # or exactly a monitor rule. A rule that is neither (mixed or other
    # sources) is never silently skipped by the checks below.
    for r in acls:
        if set(r["src"]) not in ({"tag:admin"}, {"tag:monitor"}):
            fail(f"acl entry is neither the admin rule nor the monitor rule (src={r['src']}): {r!r}")
    admin_rules = [r for r in acls if set(r["src"]) == {"tag:admin"}]
    if not admin_rules:
        fail("no tag:admin rule found — admin door missing")
    admin_dsts = set()
    for r in admin_rules:
        admin_dsts.update(r["dst"])
    extra_admin_dsts = admin_dsts - ADMIN_PORTS
    if extra_admin_dsts:
        fail(f"tag:admin grants broader than admin ports: {sorted(extra_admin_dsts)}")

    monitor_rules = [r for r in acls if set(r["src"]) == {"tag:monitor"}]
    if len(monitor_rules) != 1:
        fail(f"expected exactly one tag:monitor rule, found {len(monitor_rules)}")
    mr = monitor_rules[0]
    if mr["src"] != MONITOR_GRANT["src"] or mr["dst"] != MONITOR_GRANT["dst"]:
        fail(
            "tag:monitor grant is not the single narrow monitor->control:443 rule "
            f"(got src={mr['src']} dst={mr['dst']})"
        )

    # Nothing else may grant beyond {tag:admin, tag:monitor} sources — that
    # would be the reintroduction of a broad tailnet service mesh.
    for r in acls:
        stray_srcs = set(r.get("src", [])) - ALLOWED_TAGS
        if stray_srcs:
            fail(f"acl entry has a source outside the admin plane: {sorted(stray_srcs)} in {r!r}")

    print("ACL OK: hujson parses; tagOwners = %s; %d acl rule(s); "
          "tag:admin -> %s; tag:monitor -> control:443 (single narrow grant)."
          % (sorted(tag_owners), len(acls), sorted(admin_dsts)))


if __name__ == "__main__":
    main()
