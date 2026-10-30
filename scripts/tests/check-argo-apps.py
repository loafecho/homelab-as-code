#!/usr/bin/env python3
"""Structural checks on the Argo CD app-of-apps tree under kubernetes/.

  - every Application in kubernetes/apps/ and the root Application uses project
    `cluster`, and a repoURL the `cluster` AppProject allows;
  - every git-sourced Application points at a directory that exists and holds
    at least one manifest;
  - every workload/infra directory is owned by exactly one Application (no
    orphaned manifests that Argo would never sync);
  - the two AppProject copies (bootstrap/root.yaml, infra/rbac/appproject.yaml)
    are identical, so the self-managed copy cannot drift from the bootstrap one.

Exit 0 on success, 1 with a list of problems otherwise. Needs PyYAML.
"""
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
K8S = ROOT / "kubernetes"
problems = []


def docs(path):
    with open(path, encoding="utf-8") as f:
        return [d for d in yaml.safe_load_all(f) if d]


root_docs = docs(K8S / "bootstrap" / "root.yaml")
projects = [d for d in root_docs if d["kind"] == "AppProject"]
rbac_projects = [d for d in docs(K8S / "infra" / "rbac" / "appproject.yaml") if d["kind"] == "AppProject"]
if len(projects) != 1 or len(rbac_projects) != 1:
    problems.append("expected exactly one AppProject in bootstrap/root.yaml and in infra/rbac/appproject.yaml")
elif projects[0] != rbac_projects[0]:
    problems.append("AppProject in bootstrap/root.yaml differs from infra/rbac/appproject.yaml")
allowed = set(projects[0]["spec"]["sourceRepos"]) if projects else set()

apps = [d for d in root_docs if d["kind"] == "Application"]
for f in sorted((K8S / "apps").glob("*.yaml")):
    apps.extend(d for d in docs(f) if d["kind"] == "Application")

owned = []
for app in apps:
    name = app["metadata"]["name"]
    spec = app["spec"]
    src = spec["source"]
    if spec.get("project") != "cluster":
        problems.append(f"{name}: project is {spec.get('project')!r}, want 'cluster'")
    if src["repoURL"] not in allowed:
        problems.append(f"{name}: repoURL {src['repoURL']} not in AppProject sourceRepos")
    if "path" in src:
        d = ROOT / src["path"]
        manifests = list(d.glob("*.yaml")) if d.is_dir() else []
        if not manifests:
            problems.append(f"{name}: path {src['path']} is missing or has no manifests")
        owned.append(src["path"])
    elif "chart" not in src:
        problems.append(f"{name}: source has neither path nor chart")

for parent in ("infra", "workloads"):
    for d in sorted((K8S / parent).iterdir()):
        if not d.is_dir() or not any(d.glob("*.yaml")):
            continue
        rel = str(d.relative_to(ROOT))
        n = owned.count(rel)
        if rel == "kubernetes/infra/cilium":
            continue  # Helm-managed outside Argo on purpose (bootstrap dependency)
        if n != 1:
            problems.append(f"{rel}: owned by {n} Applications, want exactly 1")

if problems:
    print("argo-apps: FAIL")
    for p in problems:
        print("  -", p)
    sys.exit(1)
print(f"argo-apps: OK ({len(apps)} Applications, {len(owned)} git paths, all owned once)")
