#!/usr/bin/env bash
# age-key-provider.sh — OpenTofu `external` key provider (protocol v1).
#
# Unwraps the 32-byte state data key in keys/state-key.age with the YubiKey
# identity (age-plugin-yubikey). No YubiKey -> age fails -> this exits non-zero
# -> tofu refuses to touch state. That is the gate, by construction.
#
# Protocol: print the header line, read the metadata JSON (or `null`) on stdin,
# print {"keys":{"encryption_key":..,"decryption_key":..},"meta":{...}}.
# The key is never written to disk and never echoed anywhere but tofu's pipe.
#
#   FLEET_AGE_IDENTITY  identity file (default keys/yubikey-identity.txt — the
#                       age-plugin-yubikey stub, NOT a secret on its own)
#   FLEET_STATE_KEY     wrapped key  (default keys/state-key.age)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
IDENTITY="${FLEET_AGE_IDENTITY:-keys/yubikey-identity.txt}"
WRAPPED="${FLEET_STATE_KEY:-keys/state-key.age}"

echo '{"magic":"OpenTofu-External-Key-Provider","version":1}'
cat >/dev/null   # metadata input; this provider keeps none

# FLEET_STATE_KEY_B64: the key already unwrapped by scripts/fleet. tofu calls
# this provider 2-4 times per command, so without it a run asks the YubiKey ~20
# times; with it, once per plug-in. Unset -> the YubiKey path below, as always.
if [ -n "${FLEET_STATE_KEY_B64:+set}" ]; then
  key_b64=$FLEET_STATE_KEY_B64
else
  [ -r "$WRAPPED" ]  || { echo "age-key-provider: $WRAPPED missing — run scripts/new-state-key.sh (keys/README.md)" >&2; exit 1; }
  [ -r "$IDENTITY" ] || { echo "age-key-provider: $IDENTITY missing — see keys/README.md" >&2; exit 1; }
  key_b64=$(age -d -i "$IDENTITY" "$WRAPPED" | base64 -w0) \
    || { echo "age-key-provider: unwrap failed — is the YubiKey plugged in?" >&2; exit 1; }
fi
[ "$(printf '%s' "$key_b64" | base64 -d | wc -c)" -eq 32 ] \
  || { echo "age-key-provider: unwrapped key is not 32 bytes" >&2; exit 1; }

printf '{"keys":{"encryption_key":"%s","decryption_key":"%s"},"meta":{"external_data":{}}}\n' "$key_b64" "$key_b64"
