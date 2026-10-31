#!/usr/bin/env python3
"""lint-controller-tasks.py: tasks that must run on, or stay safe on, the controller.

1. Every community.proxmox.* module task under site.yml, playbooks/ and roles/
   must carry `delegate_to: localhost`, unless it sits in a playbook play with
   `hosts: localhost`. A play that targets the guests runs undelegated modules
   ON the guests, and these modules take the Proxmox API token as an argument,
   so the token would reach every guest (check mode included: the skip is
   decided inside the module, after its arguments were delivered).
2. Every get_url task must carry a `checksum:` and must not download under
   /tmp or /var/tmp: a fixed path in a shared, world-writable directory with no
   digest accepts whatever file another local user planted there first.
3. Every community.proxmox.* module task must verify the API's TLS: no literal
   `validate_certs: false`, and a `ca_path:` must be passed (the hypervisor
   serves a PVE-CA-signed certificate, so verification needs the pinned CA).
   The role default `proxmox_validate_certs` must stay true. Without this, the
   token is handed to whatever answers on :8006.

Offline: parses YAML only. Exit 0 = OK, 1 = violations (listed), 2 = usage.
"""
import pathlib
import sys

import yaml

ANSIBLE_DIR = pathlib.Path(__file__).resolve().parent.parent / "ansible"
PROXMOX_PREFIX = "community.proxmox."
FALSE_WORDS = {"false", "no", "off", "0"}
GUEST_DEFAULTS = "roles/proxmox_guest/defaults/main.yml"
GET_URL = {"get_url", "ansible.builtin.get_url", "ansible.legacy.get_url"}
SHARED_TMP = ("/tmp/", "/var/tmp/")
NESTED = ("block", "rescue", "always")


def walk_tasks(tasks):
    for t in tasks or []:
        if not isinstance(t, dict):
            continue
        yield t
        for key in NESTED:
            yield from walk_tasks(t.get(key))


def check_task(task, where, localhost_play, problems):
    name = task.get("name", "<unnamed>")
    modules = [k for k in task if isinstance(k, str)]
    if any(k.startswith(PROXMOX_PREFIX) for k in modules):
        if not localhost_play and task.get("delegate_to") != "localhost":
            problems.append(f"{where}: '{name}': community.proxmox task without delegate_to: localhost")
        for k in modules:
            if not k.startswith(PROXMOX_PREFIX):
                continue
            args = task[k] if isinstance(task[k], dict) else {}
            vc = args.get("validate_certs", True)
            if vc is False or str(vc).strip().lower() in FALSE_WORDS:
                problems.append(f"{where}: '{name}': community.proxmox task with validate_certs: false")
            if not args.get("ca_path"):
                problems.append(f"{where}: '{name}': community.proxmox task without ca_path: (pinned PVE CA)")
    for k in modules:
        if k in GET_URL:
            args = task[k] if isinstance(task[k], dict) else {}
            if not args.get("checksum"):
                problems.append(f"{where}: '{name}': get_url without checksum:")
            dest = str(args.get("dest", ""))
            if dest.startswith(SHARED_TMP) or dest in ("/tmp", "/var/tmp"):
                problems.append(f"{where}: '{name}': get_url dest under shared tmp ({dest})")


def lint_file(path, problems):
    docs = yaml.safe_load(path.read_text(encoding="utf-8")) or []
    if not isinstance(docs, list):
        return
    rel = path.relative_to(ANSIBLE_DIR)
    is_role_tasks = rel.parts[0] == "roles"
    for item in docs:
        if not isinstance(item, dict):
            continue
        if not is_role_tasks and "hosts" in item:  # a play
            localhost_play = str(item.get("hosts")).strip() in ("localhost", "127.0.0.1")
            for section in ("pre_tasks", "tasks", "post_tasks", "handlers"):
                for t in walk_tasks(item.get(section)):
                    check_task(t, rel, localhost_play, problems)
        else:  # a task (role task/handler file, or an imported task list)
            for t in walk_tasks([item]):
                check_task(t, rel, False, problems)


def main():
    if not ANSIBLE_DIR.is_dir():
        print(f"lint-controller-tasks: no ansible dir at {ANSIBLE_DIR}", file=sys.stderr)
        sys.exit(2)
    files = [ANSIBLE_DIR / "site.yml"]
    files += sorted((ANSIBLE_DIR / "playbooks").glob("*.yml"))
    for sub in ("tasks", "handlers"):
        files += sorted((ANSIBLE_DIR / "roles").glob(f"*/{sub}/*.yml"))
    problems = []
    defaults = yaml.safe_load((ANSIBLE_DIR / GUEST_DEFAULTS).read_text(encoding="utf-8")) or {}
    if defaults.get("proxmox_validate_certs") is not True:
        problems.append(f"{GUEST_DEFAULTS}: proxmox_validate_certs must be true")
    if not defaults.get("proxmox_ca_path"):
        problems.append(f"{GUEST_DEFAULTS}: proxmox_ca_path must point at the pinned PVE CA")
    for f in files:
        if f.is_file():
            lint_file(f, problems)
    if problems:
        print("LINT FAIL: controller-only task rules violated:")
        for p in problems:
            print("  " + p)
        sys.exit(1)
    print(f"lint-controller-tasks: OK ({len(files)} files; community.proxmox delegated + TLS-verified, get_url checksummed)")


if __name__ == "__main__":
    main()
