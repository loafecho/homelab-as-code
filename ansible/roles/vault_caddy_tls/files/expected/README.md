# Expected render baseline: vault_caddy_tls

Committed reference for the render diff in `scripts/drift-check.sh` and CI.
Rendered from the example inventory with
`ansible-playbook playbooks/render-caddy.yml` and reviewed by hand: listener
:443, TLS paths under /etc/caddy/tls, `reverse_proxy 127.0.0.1:80`, tbot join
token referenced as a runtime file path only (no secret value present).

Provenance lives here, not as headers inside the baseline files: they must stay
byte-identical to the render or the diff false-fires.
