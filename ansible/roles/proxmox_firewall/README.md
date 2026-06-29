# role: `proxmox_firewall`

Renders Proxmox host firewall rule files from the firewall data model:

- **`<vmid>.fw`**: one per guest, from the `firewall:` block in
  `host_vars/<guest>.yml`. Source names (`guest` / `group:NAME` /
  `ref:admin_devices` / `internet`) are resolved to IPs through the `guests`
  map in `group_vars/all.yml`.
- **`cluster.fw`**: datacenter level. Carries the hypervisor's :8006 console
  allow for `admin_devices` (a HOST port, so it does not belong in any
  `<vmid>.fw`).

## Staging only

Output goes to **`build/firewall/`** (gitignored) for review. `firewall_apply`
defaults to **false**: nothing is written to `/etc/pve/firewall` and nothing is
applied.

```bash
ansible-playbook playbooks/render-firewall.yml
diff -ru -x README.md roles/proxmox_firewall/files/expected build/firewall
```

The committed baselines in `files/expected/` are the reviewed render of the
example inventory. CI re-renders and diffs against them, so a template or data
change that alters a rule shows up as a reviewable diff.

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
that must dial out (the `tbot` agent from `roles/vault_caddy_tls`, renewing its
certificate with Teleport) needs a narrow entry keyed on `dest`:

```yaml
egress:
  - { dest: teleport, port: 3025, proto: tcp, enabled: true, comment: "..." }
```

That renders to an `OUT ACCEPT -dest <ip> -p <proto> -dport <port>` line, using
the same `group:` / `ref:` / plain-name resolution as ingress `src`.
