# shellcheck shell=bash
# scripts/lib/unlock.sh — YubiKey helpers for scripts/fleet. Source it from the
# opentofu/ directory after defining fail() (print the reason and exit). Each
# unwrap is a PIN/touch for the operator, so callers unwrap once per run and
# hand the result to tofu through the environment.
#
#   FLEET_AGE_IDENTITY  identity file (default keys/yubikey-identity.txt)
#   FLEET_STATE_KEY     wrapped state key (default keys/state-key.age)

FLEET_IDENTITY=${FLEET_AGE_IDENTITY:-keys/yubikey-identity.txt}
FLEET_WRAPPED=${FLEET_STATE_KEY:-keys/state-key.age}

# Throw away anything typed ahead, so a stray Enter can't answer the next prompt.
drain() { while read -r -t 0.1 -n 256 _ 2>/dev/null </dev/tty; do :; done; }
pin_tries() { ykman piv info 2>/dev/null | awk -F': *' '/PIN tries remaining/ { split($2, a, "/"); print a[1] }'; }
require_tty() {
  { : </dev/tty; } 2>/dev/null || fail "no terminal: run it with ssh -t (the YubiKey PIN needs your keyboard)"
}

# One YubiKey unwrap of the state key into FLEET_STATE_KEY_B64 (exported, never
# printed). scripts/age-key-provider.sh hands it to tofu instead of asking again.
unlock_state_key() {
  local tries k
  tries=$(pin_tries)
  if [ -n "$tries" ] && [ "$tries" -le 1 ]; then
    fail "the YubiKey has $tries PIN try left: stop, don't guess (3 wrong in a row locks the PIN)"
  fi
  [ -n "$tries" ] && [ "$tries" -lt 3 ] && echo "NOTE: $tries PIN tries left; a correct PIN resets it to 3."
  drain
  echo ">>> YubiKey: type its PIN when asked (the prompt clears after Enter), then tap the key if it blinks."
  if ! k=$(set -o pipefail; age -d -i "$FLEET_IDENTITY" "$FLEET_WRAPPED" | base64 -w0); then
    echo "    PIN tries left now: $(pin_tries)"
    fail "could not unlock the state key with the YubiKey"
  fi
  [ "$(printf '%s' "$k" | base64 -d | wc -c)" -eq 32 ] || fail "unlocked state key is not 32 bytes"
  FLEET_STATE_KEY_B64=$k
  export FLEET_STATE_KEY_B64
  echo "    unlocked."
}

# One YubiKey unwrap of an age-encrypted Proxmox token into TF_VAR_pve_api_token
# (exported, never printed). Run it right after unlock_state_key: the YubiKey is
# usually still unlocked then, so it rarely asks for the PIN a second time.
unlock_token() {
  local t
  t=$(age -d -i "$FLEET_IDENTITY" "$1") || fail "could not unlock $1"
  [[ $t == 'tofu@pve!pilot='* ]] || fail "token in $1 doesn't look like tofu@pve!pilot=…"
  TF_VAR_pve_api_token=$t
  export TF_VAR_pve_api_token
}
