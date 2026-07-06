# role: `vault_caddy_tls`

Thin Caddy TLS front for the **vault** guest (self-hosted Infisical), closing a
port mismatch between the data model and the live service.

## The problem

`group_vars/all.yml` declares `vault_endpoint.port: 443` and
`host_vars/vault.yml` allows `group:secret_consumers -> vault:443`. But
Infisical's container serves **plain HTTP on :80**; nothing listens on :443.
If the firewall flip lands (`policy_in: DROP` with no `:80` rule for
consumers), every `secret_consumer` would silently fail: it would hit a dead
:443 while :80, the port that actually works, is dropped.

## The fix

Caddy listens on **:443** and reverse-proxies to local Infisical `:80`, serving
a certificate issued and renewed through **Teleport's OSS `db` CA**
(`tctl auth sign` + `tbot`), deliberately **not** Enterprise Workload Identity /
SPIFFE SVIDs, which are license-gated. Teleport stays **out of the secret data
path**: it only mints and renews cert material. If Teleport or tbot is down,
Caddy keeps serving its last cert until expiry and secret fetches are
unaffected. No new single point of failure.

```
secret_consumer --(TLS :443)--> Caddy on vault --(plain HTTP :80)--> Infisical
                                    ^
                                    | cert from /etc/caddy/tls/*, kept fresh by tbot
                                    | (tbot <-auth/renew-- Teleport `db` CA)
```

## Staged by default

`vault_caddy_tls_deploy` defaults to **`false`** (the same pattern as
`firewall_apply` in `roles/proxmox_firewall`). With the default:

- `tasks/main.yml` only renders `Caddyfile` + `tbot.yaml` to **`build/caddy/`**
  (gitignored) for review.
- `tasks/deploy.yml` (Caddy install, tbot binary push, systemd units) is
  **skipped entirely**.

```bash
ansible-playbook playbooks/render-caddy.yml
diff -ru -x README.md roles/vault_caddy_tls/files/expected build/caddy
docker run --rm -v "$PWD/build/caddy:/cfg" caddy:2-alpine \
  caddy validate --config /cfg/Caddyfile --adapter caddyfile   # optional
```

## Going live (explicit, not part of routine `site.yml` runs)

1. On the teleport guest, out of band: confirm the `db` CA exists
   (`tctl status`), register a placeholder database resource
   (`teleport_db_resource_name`, default `vault-tls-front`) so tbot's
   `database` output has a target to sign against, and mint a bot join token
   (`tctl bots add vault-caddy-tls --roles=<db-signing-role>`). Land the token
   at `/run/tbot/join-token` on vault out of band. **Never in git.**
2. `ansible-playbook site.yml --limit vault -e vault_caddy_tls_deploy=true`.
   vault's firewall has `policy_out: DROP`, so the tbot binary is fetched by
   the **control node** and pushed over the existing control→vault:22 channel;
   vault never fetches anything itself.
3. Verify from a secret consumer: `curl -vk https://<vault-ip>/api/status`.
4. Only then consider any firewall change that drops legacy `:80` traffic.
