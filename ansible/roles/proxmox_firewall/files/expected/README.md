# Expected render baseline: proxmox_firewall

Committed reference for the render diff in `scripts/drift-check.sh` and CI.
Rendered from the example inventory with
`ansible-playbook playbooks/render-firewall.yml` and reviewed by hand
(policies, resolved source IPs, disabled-rule comments).

**Re-rendered 2026-11-02** after the firewall rework: every diff was reviewed
against the live listener captures in `../listeners/` (and
`scripts/tests/check-fw-coverage.py`): UDP 41641 for each guest running
tailscaled, telemetry -> vault :9100, DNS + NTP egress for vault, vault's LAN
:443 rules and the tbot egress retired with the unused Caddy TLS front, the
deploy box in the management IPSET (the monitor Pi's LAN rules retired with
it), hypervisor listener rules in `cluster.fw`, LAN ingress for control, media,
teleport, kube and email from their `ss -tulnp` captures, and `180.fw`
(engine) and `901.fw` (email) added. 8 .fw files now.

Provenance lives here, not as headers inside the baseline files: they must stay
byte-identical to the render or the diff false-fires.

Re-render and re-review whenever `guest.fw.j2` / `cluster.fw.j2` or the
firewall data in host_vars/group_vars changes. A stale baseline reads as false
DRIFT, not false clean, which is the safe direction.
