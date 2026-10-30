#!/usr/bin/env bash
# fleet-smoke.sh — rehearse an import with scripts/fleet WITHOUT the YubiKey,
# the Proxmox token or Proxmox, in a throwaway copy:
#   - Proxmox is fake_pve.py replaying the hypervisor's recorded read-only
#     answers (replay/worker.json: CT 102 already in pool pilot). It logs every
#     call and answers 401 to anything but the token.
#     Its certificate is fleet's pinned CA (FLEET_PVE_CA), so TLS is
#     verified exactly as against the real hypervisor.
#   - the YubiKey is a throwaway age key; the state key and the token are
#     throwaway too, encrypted to it (the real keys/*.age are never copied).
#   - every age decrypt is counted per fleet run: each is a PIN/touch for the operator.
# Runs, each in a pty like `ssh -t`: fleet apply (no plan yet), fleet init,
# fleet plan, fleet apply, fleet plan, fleet state list. Checks (each one is
# proven able to fail by fleet-smoke-controls.sh):
#   A  apply without a saved plan refuses, before any YubiKey unwrap
#   B  the first plan is exactly "Plan: 1 to import, 0 to add, 0 to change, 0 to destroy."
#   C  apply completes: 1 imported, 0 added, 0 changed, 0 destroyed
#   W  Proxmox got no writes (POST/PUT/DELETE) in the whole run
#   D  the second plan is "No changes."
#   E  at most 2 YubiKey unwraps per fleet run
#   F  the token and the state key are in no output, log or file
#   G  every Proxmox call carried the token
#   R  every GET was answered from the replay (none made up)
#
#   bash scripts/smoke/fleet-smoke.sh        # PASS = "RESULT: fleet smoke passed"
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
S=$(mktemp -d "${TMPDIR:-/tmp}/fleet-smoke.XXXXXX")
fpid=
trap '[ -n "$fpid" ] && kill "$fpid" 2>/dev/null; rm -rf -- "$S"' EXIT
rsync -a --exclude .git --exclude 'terraform.tfstate*' --exclude '*.tfplan' --exclude '*.log' \
  --exclude keys/state-key.age --exclude keys/pve-token.age "$REPO/" "$S/repo/"

# throwaway "YubiKey", state key and token; the secrets live only in this shell
age-keygen -o "$S/repo/keys/smoke-identity.txt" 2>/dev/null
pub=$(age-keygen -y "$S/repo/keys/smoke-identity.txt")
key_b64=$(head -c 32 /dev/urandom | base64 -w0)
key_hex=$(printf '%s' "$key_b64" | base64 -d | od -An -tx1 | tr -d ' \n')
printf '%s' "$key_b64" | base64 -d | age -r "$pub" -o "$S/repo/keys/state-key.age"
secret=$(cat /proc/sys/kernel/random/uuid)
printf 'tofu@pve!pilot=%s\n' "$secret" | age -r "$pub" -o "$S/repo/keys/pve-token.age"

# the fake Proxmox, replaying the recorded hypervisor answers
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
  -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 -keyout "$S/key.pem" -out "$S/cert.pem" 2>/dev/null
port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
: > "$S/pve.log"
FAKE_PVE_MAC=$(printf 'BC:24:11:%02X:%02X:%02X' "$((RANDOM % 256))" "$((RANDOM % 256))" "$((RANDOM % 256))") \
FAKE_PVE_AUTH_SHA256=$(printf 'PVEAPIToken=tofu@pve!pilot=%s' "$secret" | sha256sum | cut -d' ' -f1) \
  python3 "$REPO/scripts/smoke/fake_pve.py" "$port" "$S/cert.pem" "$S/key.pem" "$S/pve.log" \
  "$REPO/scripts/smoke/replay/worker.json" &
fpid=$!
for _ in $(seq 100); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.1; done

mkdir -p "$S/shim" "$S/home"
cat > "$S/shim/ykman" <<'SH'
#!/usr/bin/env bash
echo "PIN tries remaining:      3/3"
SH
cat > "$S/shim/age" <<SH
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = -d ] && echo decrypt >> "$S/unwraps.log"; done
exec $(command -v age) "\$@"
SH
chmod +x "$S/shim/"*
: > "$S/unwraps.log"

fails=0 runs=()
ok()  { echo "SMOKE: $*"; }
bad() { echo "SMOKE FAIL: $*"; fails=$((fails + 1)); }
# one fleet command in a pty, as an operator runs it; leaves $rc, $n (unwraps), $S/out.txt
fleet() {
  local before
  before=$(wc -l < "$S/unwraps.log")
  echo "=== fleet $*"
  rc=0
  HOME="$S/home" PATH="$S/shim:$PATH" FLEET_AGE_IDENTITY=keys/smoke-identity.txt \
    FLEET_PVE_ENDPOINT="https://127.0.0.1:$port/" FLEET_PVE_CA="$S/cert.pem" \
    python3 "$REPO/scripts/smoke/pty_driver.py" "$S" bash "$S/repo/scripts/fleet" "$@" \
    | tr -d '\r' > "$S/out.txt" || rc=$?
  n=$(( $(wc -l < "$S/unwraps.log") - before ))
  cat "$S/out.txt" >> "$S/terminal.txt"   # every run's screen output, for check F
  grep -v '^[[:space:]]*$' "$S/out.txt" | sed 's/^/  | /' || true
  echo "  (exit $rc, YubiKey unwraps: $n)"
  runs+=("$* $n")
}
has() { grep -qxF -- "$1" "$S/out.txt"; }

fleet apply
if [ "$rc" -ne 0 ] && grep -q 'no saved plan' "$S/out.txt" && [ "$n" -eq 0 ]; then
  ok "A apply without a saved plan refused before the YubiKey (exit $rc, 0 unwraps)"
else
  bad "A apply without a saved plan was not refused before the YubiKey (exit $rc, $n unwraps)"
fi
unwraps_refused=$n

fleet init
[ "$rc" -eq 0 ] || bad "fleet init failed (exit $rc)"

fleet plan
IMPORT_ONLY='Plan: 1 to import, 0 to add, 0 to change, 0 to destroy.'
if [ "$rc" -eq 0 ] && has "$IMPORT_ONLY"; then
  ok "B first plan: $IMPORT_ONLY"
else
  bad "B first plan is not import-only (exit $rc; got: $(grep -m1 -E '^(Plan:|No changes|Error)' "$S/out.txt" || echo nothing))"
fi

fleet apply
APPLIED='Apply complete! Resources: 1 imported, 0 added, 0 changed, 0 destroyed.'
if [ "$rc" -eq 0 ] && has "$APPLIED"; then
  ok "C $APPLIED"
else
  bad "C apply did not just import (exit $rc; got: $(grep -m1 -E '^(Apply complete|Error)' "$S/out.txt" || echo nothing))"
fi

fleet plan
if [ "$rc" -eq 0 ] && grep -q '^No changes\.' "$S/out.txt"; then
  ok "D second plan: $(grep -m1 '^No changes\.' "$S/out.txt")"
else
  bad "D second plan is not 'No changes.' (exit $rc; got: $(grep -m1 -E '^(Plan:|Error)' "$S/out.txt" || echo nothing))"
fi

fleet state list
grep -qxF proxmox_virtual_environment_container.worker "$S/out.txt" \
  || bad "state does not list proxmox_virtual_environment_container.worker"

echo
# W, G, R: what the fake Proxmox saw
read -r gets writes noauth unknown paths < <(python3 -c '
import json, sys
g = w = b = u = 0; seen = []
for line in open(sys.argv[1]):
    e = json.loads(line)
    p = e["p"].removeprefix("/api2/json") + ("?" + e["q"] if e["q"] else "")
    if e["m"] == "GET":
        g += 1
        if p not in seen: seen.append(p)
    else:
        w += 1
    b += e.get("auth") != "ok"
    u += bool(e.get("unknown"))
print(g, w, b, u, ",".join(seen) or "-")' "$S/pve.log")
if [ "$writes" -eq 0 ] && [ "$gets" -gt 0 ]; then
  ok "W Proxmox got $gets GETs and 0 writes; paths: $paths"
else
  bad "W Proxmox got writes: $writes POST/PUT/DELETE ($gets GETs)"
fi
if [ "$noauth" -eq 0 ] && [ "$gets" -gt 0 ]; then
  ok "G every Proxmox call carried the token"
else
  bad "G Proxmox calls without the right token: $noauth"
fi
if [ "$unknown" -eq 0 ]; then
  ok "R every GET was answered from the replay"
else
  bad "R calls missing from the replay: $unknown"
fi

# E: unwraps per run (the refused apply must not touch the YubiKey at all)
over=0
for r in "${runs[@]}"; do [ "${r##* }" -le 2 ] || over=1; done
summary=$(printf '%s, ' "${runs[@]}"); summary=${summary%, }
if [ "$over" -eq 0 ] && [ "$unwraps_refused" -eq 0 ]; then
  ok "E YubiKey unwraps per fleet run: $summary (allowed: 2)"
else
  bad "E too many YubiKey unwraps per fleet run: $summary (allowed: 2)"
fi

# F: neither secret anywhere: terminal output, fleet.log, the fake's log, state, plan, any file
leaks=$(grep -rlaF -e "$secret" -e "$key_b64" -e "$key_hex" "$S" 2>/dev/null | sed "s|$S/||" | tr '\n' ' ' || true)
if [ -z "$leaks" ]; then
  ok "F no token or state key in any output, log or file ($(find "$S" -type f | wc -l) files searched)"
else
  bad "F a secret reached: $leaks"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "RESULT: fleet smoke passed"
else
  echo "RESULT: fleet smoke FAILED ($fails checks)"
  exit 1
fi
