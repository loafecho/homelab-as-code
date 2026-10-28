#!/usr/bin/env bash
# new-state-key.sh — ONE-TIME: mint the 32-byte state data key and wrap it to
# both recipients in keys/recipients.txt (YubiKey + paper backup). Run once by
# the operator with the YubiKey plugged in (keys/README.md). Refuses to overwrite.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
RECIPIENTS=keys/recipients.txt
OUT=keys/state-key.age

[ -e "$OUT" ] && { echo "refusing: $OUT exists — rotating the key is its own change" >&2; exit 1; }
if grep -q 'PLACEHOLDER' "$RECIPIENTS"; then
  echo "refusing: $RECIPIENTS still has placeholders — add the real YubiKey and paper recipients first" >&2
  exit 1
fi
n=$(grep -cE '^age1' "$RECIPIENTS" || true)
[ "$n" -ge 2 ] || { echo "refusing: need >= 2 recipients (YubiKey + paper), found $n" >&2; exit 1; }

head -c 32 /dev/urandom | age -R "$RECIPIENTS" -o "$OUT"
echo "wrote $OUT ($(wc -c <"$OUT") bytes, $n recipients). Commit it; it is useless without a recipient's identity."
