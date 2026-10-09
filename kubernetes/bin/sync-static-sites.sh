#!/usr/bin/env bash
# Copy static sites from local directories into the static-sites PVC.
#
#   kubernetes/bin/sync-static-sites.sh <src-dir> <name> [<src-dir> <name> ...]
#
# Each site is swapped in whole: extracted to /srv/<name>.new inside the pod,
# then moved over the old copy (the clean-up commands run INSIDE the pod, on
# /srv only). Re-run after editing any source directory.
set -euo pipefail
if [ $# -lt 2 ] || [ $(($# % 2)) -ne 0 ]; then
  echo "usage: $0 <src-dir> <name> [<src-dir> <name> ...]" >&2
  exit 2
fi
POD=$(kubectl get pods -n apps -l app=static-sites -o jsonpath='{.items[0].metadata.name}')
[ -n "$POD" ] || { echo "no static-sites pod" >&2; exit 1; }
sync() {   # src_dir dest_name
  local src="$1" dst="$2"
  [[ $dst =~ ^[a-z0-9-]+$ ]] || { echo "!! bad site name: $dst (use a-z, 0-9, -)" >&2; return 1; }
  [ -d "$src" ] || { echo "!! missing $src" >&2; return 1; }
  tar -C "$src" -cf - . | kubectl exec -i -n apps "$POD" -- sh -c \
    "set -e; d=/srv/$dst; rm -rf \$d.new; mkdir -p \$d.new; tar -C \$d.new -xf -; rm -rf \$d.old; [ -d \$d ] && mv \$d \$d.old || true; mv \$d.new \$d; rm -rf \$d.old"
  echo "synced $dst ($(find "$src" -type f | wc -l) files)"
}
while [ $# -gt 0 ]; do
  sync "$1" "$2"
  shift 2
done
