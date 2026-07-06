# role: `tailscale_acl`

Validates and stages the slimmed, admin-plane-only Tailscale ACL
(`files/acl.hujson`). Segmentation lives in the Proxmox host firewall
(`roles/proxmox_firewall`); the tailnet is demoted to the administrator's
remote door:

- `tag:admin` (admin devices, owned by `autogroup:admin`) → `*:22`, `*:443`, `*:8006`.
- `tag:monitor` (the monitoring Pi) → exactly **one** narrow grant: `control:443`.
- No other source may appear in `acls`; that would be the broad tailnet
  service mesh this ACL replaces.

## Validate and stage only, never push

1. `validate_acl.py` parses `acl.hujson` as hujson (JSON + `//`/`/* */`
   comments + trailing commas, no external deps) and asserts it matches the
   policy above. It is a pure offline lint: no network calls, no tailnet
   credentials, no `tailscale` CLI login.
2. The validated file is copied to `build/tailscale/acl.hujson` (gitignored,
   same staging pattern as `roles/proxmox_firewall`) for human review.
3. `tailscale_acl_apply` defaults to **false**. Even if flipped true, this
   role has **no code path that reaches the Tailscale API**. A wrong ACL
   pushed live is a lockout risk, so the push is left to a reviewed,
   snapshot-of-current-ACL-first change.

```bash
ansible-playbook playbooks/validate-tailscale-acl.yml
python3 roles/tailscale_acl/files/validate_acl.py roles/tailscale_acl/files/acl.hujson
```

## Break-glass note

This ACL only gates the *tailnet* admin door. The break-glass paths that must
survive a tailnet outage (LAN SSH from `admin_devices`, the hypervisor's :8006
console) are enforced by the host firewall data model in
`inventory/group_vars/all.yml` / `inventory/host_vars/*.yml`, rendered by
`roles/proxmox_firewall`.
