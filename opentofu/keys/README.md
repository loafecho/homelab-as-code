# keys/

Nothing secret lives here, and in this public copy nothing real lives here at
all: the `.age` files and identity stubs are gitignored. The layout an operator
creates on the deploy box:

| File | What | Secret? |
|---|---|---|
| `recipients.txt` | age public keys: the YubiKey (age-plugin-yubikey) and an offline paper backup | no |
| `yubikey-identity.txt` | age-plugin-yubikey identity stub (points at the key's PIV slot) | no; useless without the YubiKey |
| `state-key.age` | the 32-byte state data key, wrapped to both recipients | no; useless without a recipient |
| `pve-token.age` | the pool-scoped Proxmox API token, encrypted to both recipients | no; useless without a recipient |
| `pve-root-ca.pem` | the hypervisor's `/etc/pve/pve-root-ca.pem`; `scripts/fleet` verifies the Proxmox API's TLS against it (`SSL_CERT_FILE`) and refuses to plan or apply without it | no; a public CA certificate |

One-time setup:

1. `age-plugin-yubikey` → write the identity stub to `yubikey-identity.txt` and
   its recipient to `recipients.txt`.
2. Generate the paper key offline (`age-keygen`), print it, and add only its
   **public** half to `recipients.txt`. The secret half never touches a
   networked machine.
3. `scripts/new-state-key.sh` mints the state key and wraps it to both
   recipients. It refuses placeholders, fewer than two recipients, or an
   existing key.
4. Encrypt the API token: `age -R keys/recipients.txt -o keys/pve-token.age`.
5. Copy the hypervisor's `/etc/pve/pve-root-ca.pem` to `keys/pve-root-ca.pem`
   over a channel you already trust (e.g. the console), and compare its
   fingerprint with `openssl x509 -noout -fingerprint -sha256` on both ends.
   TLS verification is never switched off: `pve_insecure` must stay false.

`recipients.txt.example` shows the expected shape.
