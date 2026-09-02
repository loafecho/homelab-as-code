#!/usr/bin/env bash
# check-renders.sh — render the staging artifacts from the example inventory and
# diff them against the committed, hand-reviewed baselines. Localhost only: no
# hypervisor, no tailnet, no credentials.
#
#   build/firewall             vs ansible/roles/proxmox_firewall/files/expected/
#   build/caddy                vs ansible/roles/vault_caddy_tls/files/expected/
#   build/tailscale/acl.hujson vs ansible/roles/tailscale_acl/files/acl.hujson
#
# Exit 0 = renders match, 1 = a render differs (the diff is printed),
# 2 = a render playbook failed.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../ansible" || exit 2

for pb in playbooks/render-firewall.yml playbooks/validate-tailscale-acl.yml playbooks/render-caddy.yml; do
  if ! out=$(ansible-playbook "$pb" 2>&1); then
    echo "check-renders: render playbook FAILED: $pb"
    echo "$out" | tail -20
    exit 2
  fi
done

rc=0
diff -ru -x README.md roles/proxmox_firewall/files/expected build/firewall || rc=1
diff -ru -x README.md roles/vault_caddy_tls/files/expected build/caddy || rc=1
diff -u roles/tailscale_acl/files/acl.hujson build/tailscale/acl.hujson || rc=1
if [ "$rc" -eq 0 ]; then
  echo "check-renders: OK (firewall, caddy, tailscale ACL match their baselines)"
else
  echo "check-renders: DRIFT (see diff above; re-review and update the baseline if intended)"
fi
exit "$rc"
