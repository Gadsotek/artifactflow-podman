#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
generator=/usr/lib/systemd/system-generators/podman-system-generator
if [ ! -x "$generator" ]; then
  generator=/usr/libexec/podman/quadlet
fi
[ -x "$generator" ] || { echo 'Install Podman 5+ to validate generated units.' >&2; exit 1; }
output="$(mktemp)"
trap 'rm -f "$output"' EXIT
QUADLET_UNIT_DIRS="$root/quadlet" "$generator" --user --dryrun > "$output" 2>&1
if grep -Ei 'unsupported key|failed to|error:' "$output"; then
  exit 1
fi
for file in "$root"/quadlet/*.container; do
  name="$(basename "$file" .container)"
  grep -F -- "---$name.service---" "$output" >/dev/null || {
    echo "Generator omitted $name" >&2; exit 1;
  }
done
for gid in 10001 10002 10003 10004; do
  grep -F -- "--group-add $gid " "$output" >/dev/null || {
    echo "Missing separate socket group argument $gid" >&2; exit 1;
  }
done
echo 'Quadlet generation: OK'
