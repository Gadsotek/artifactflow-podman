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

unit_exec_start() {
  awk -v unit="$1" '
    $0 == "---" unit ".service---" { inside=1; next }
    /^---.*\.service---$/ { inside=0 }
    inside && /^ExecStart=/ { print; exit }
  ' "$output"
}

relay_exec="$(unit_exec_start artifactflow-artifact-ingress)"
[ -n "$relay_exec" ] || { echo 'Missing artifact ingress ExecStart' >&2; exit 1; }
for expected in \
  '--entrypoint /usr/bin/socat' \
  '--network artifactflow-edge --network artifactflow-artifact-ingress' \
  '--publish 127.0.0.1:8081:8081' \
  '--sysctl net.ipv4.ip_forward=0' \
  '--health-cmd' \
  'localhost/artifactflow-image-parser:pinned TCP4-LISTEN:8081,bind=0.0.0.0,reuseaddr,fork TCP4:artifactflow-artifact-host:8081'; do
  [[ "$relay_exec" == *"$expected"* ]] || {
    echo "Artifact ingress is missing generated argument: $expected" >&2; exit 1;
  }
done
relay_health="${relay_exec#*--health-cmd }"
relay_health="${relay_health%% --health-interval*}"
[[ "$relay_health" == *'socat'* ]] || {
  echo 'Artifact ingress healthcheck must exercise its socat HTTP path' >&2; exit 1;
}
[[ "$relay_exec" != *'healthcheck.php'* ]] || {
  echo 'Artifact ingress inherited the parser healthcheck' >&2; exit 1;
}
artifact_host_exec="$(unit_exec_start artifactflow-artifact-host)"
[[ "$artifact_host_exec" == *'--network artifactflow-artifact --network artifactflow-artifact-ingress'* ]] || {
  echo 'Artifact host is missing its two internal networks' >&2; exit 1;
}
[[ "$artifact_host_exec" != *'--publish'* ]] || {
  echo 'Artifact host must not publish directly from an internal network' >&2; exit 1;
}
[[ "$artifact_host_exec" == *'--sysctl net.ipv4.ip_forward=0'* ]] || {
  echo 'Artifact host must not forward packets between its internal networks' >&2; exit 1;
}

for gid in 10001 10002 10003 10004; do
  grep -F -- "--group-add $gid " "$output" >/dev/null || {
    echo "Missing separate socket group argument $gid" >&2; exit 1;
  }
done
echo 'Quadlet generation: OK'
