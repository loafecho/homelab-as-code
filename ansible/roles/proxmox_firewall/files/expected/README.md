# Expected render baseline: proxmox_firewall

Committed reference for the render diff in `scripts/drift-check.sh` and CI.
Rendered from the example inventory with
`ansible-playbook playbooks/render-firewall.yml` and reviewed by hand
(policies, resolved source IPs, disabled-rule comments).

Provenance lives here, not as headers inside the baseline files: they must stay
byte-identical to the render or the diff false-fires.

Re-render and re-review whenever `guest.fw.j2` / `cluster.fw.j2` or the
firewall data in host_vars/group_vars changes. A stale baseline reads as false
DRIFT, not false clean, which is the safe direction.
