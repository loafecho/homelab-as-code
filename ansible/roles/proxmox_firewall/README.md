# role: `proxmox_firewall`

Renders Proxmox host firewall rule files from the firewall data model:

- **`<vmid>.fw`**: one per guest, from the `firewall:` block in
  `host_vars/<guest>.yml`. Source names (`guest` / `group:NAME` /
  `ref:admin_devices` / `internet` or `any` / `lan` / `mgmt`) are resolved to
  IPs through the maps in `group_vars/all.yml`. `lan` is `lan_cidr`; `mgmt` is
  the management set (`firewall_mgmt_sources`: admin devices, the control
  node and the OpenTofu deploy box).
- **`cluster.fw`**: datacenter level. Carries the `management` IPSET, the
  hypervisor's :8006 console allow for `admin_devices` and the hypervisor's own
  listeners (`firewall_host_rules`). These are HOST ports, so they do not
  belong in any `<vmid>.fw`. `policy_in` is `firewall_cluster_policy_in`
  (default DROP; the first live step uses ACCEPT).
- **`host.fw`**: node level. Only `nf_conntrack_max`: while the firewall is on,
  pve-firewall writes the conntrack table size from this file on every compile
  and overrides `/etc/sysctl.d`.

## Staged by default, applied by a gated playbook

The default run renders to **`build/firewall/`** (gitignored) for review;
nothing is written to `/etc/pve/firewall`.

```bash
ansible-playbook playbooks/render-firewall.yml
diff -ru -x README.md roles/proxmox_firewall/files/expected build/firewall
```

The committed baselines in `files/expected/` are the reviewed render of the
example inventory. CI re-renders and diffs against them, so a template or data
change that alters a rule shows up as a reviewable diff.

The live install is `playbooks/apply-firewall.yml` (`tasks/apply.yml`). It
refuses a non-check run unless `-e firewall_apply_confirm=apply-live-firewall`
is passed, so `--check --diff` is the default use. It raises the conntrack
table first, then writes `host.fw`, `cluster.fw` and each `<vmid>.fw`
(or only the files named in `firewall_apply_files`). pmxcfs refuses the
template module's atomic write, so each file is rendered to
`firewall_stage_dir` on the host, copied in with `cp` and compared with `cmp`.
Arm `scripts/fw-rollback.sh` on the hypervisor before every live step.

## Coverage against live listeners

`files/listeners/<vmid>.txt` (and `host.txt` for the hypervisor) are captures
of each guest's listening sockets from `scripts/capture-listeners.sh`, reduced
to LAN-reachable lines for this public copy. `scripts/tests/check-fw-coverage.py`
requires every LAN listener to be allowed by the rendered rules, covered by a
Proxmox built-in, or listed with a reason in `files/listeners/closed.yml`, so a
firewall flip cannot silently cut a live service. It also fails on any rule
that names an address the inventory does not know.

## Rule encoding

- `enabled: true`  → active `IN ACCEPT` line.
- `enabled: false` → emitted as a `# DISABLED:` comment (visible for review,
  inert when applied), e.g. every rule that needs the unbuilt gateway.
- Unresolvable source (no IP yet) → `# UNRESOLVED` comment.
- `policy_in: DROP` everywhere (default-deny); `policy_out: DROP` only on vault.

## Egress allow-list (`firewall.egress`)

Every guest except vault runs `policy_out: ACCEPT`, so their `egress: []` is a
no-op by design. vault is the one guest with `policy_out: DROP`;
`always_allow_established` only lets return traffic back in on connections it
did not open, it does **not** open any new outbound path. A process on vault
that must dial out (tailscaled's control and relay sessions, DNS to the LAN
resolvers, NTP) needs a narrow entry keyed on `dest`:

```yaml
egress:
  - { dest: ref:dns_servers, port: 53, proto: udp, enabled: true, comment: "..." }
```

That renders to an `OUT ACCEPT -dest <ip> -p <proto> -dport <port>` line, using
the same `group:` / `ref:` / plain-name resolution as ingress `src`.
