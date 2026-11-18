#!/bin/sh
set -eu

# Apply the committed deployment state of this repository to the local VM.
#
# Run on the VM as the artifactflow user, from the repo clone:
#   ./deploy.sh              pull, verify, prepare enabled processors, restart
#   ./deploy.sh --no-pull    deploy the working tree as-is (no git pull)
#   ./deploy.sh --no-verify  skip attestation verification only when every
#                            deployed digest was verified elsewhere
#
# This script never edits the config directory ($CFG, default
# ~/.config/artifactflow, override with ARTIFACTFLOW_CONFIG_DIR). Processor
# enablement and secrets remain installer/operator decisions. If the release
# changes the restricted artifact-host grants, re-apply that manifest after
# the migration.

no_pull=0
no_verify=0
for arg in "$@"; do
  case "$arg" in
    --no-pull) no_pull=1 ;;
    --no-verify) no_verify=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

CFG="${ARTIFACTFLOW_CONFIG_DIR:-$HOME/.config/artifactflow}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

read_value() {
  sed -n "s|^$1=||p" "$2" | head -n1
}

processor_image_ref() {
  case "$1" in
    PDF) read_value PDF_PROCESSOR_IMAGE processor-images.lock ;;
    XLSX) read_value XLSX_PROCESSOR_IMAGE processor-images.lock ;;
    DOCX) read_value DOCX_PROCESSOR_IMAGE processor-images.lock ;;
    *) die "Unknown processor: $1" ;;
  esac
}

processor_local_tag() {
  case "$1" in
    PDF) echo localhost/artifactflow-pdf-processor:pinned ;;
    XLSX) echo localhost/artifactflow-xlsx-processor:pinned ;;
    DOCX) echo localhost/artifactflow-docx-processor:pinned ;;
    *) die "Unknown processor: $1" ;;
  esac
}

require_processor_image() {
  kind="$1"
  ref="$(processor_image_ref "$kind")"
  case "$kind" in
    PDF) expected=artifactflow-pdf-processor ;;
    XLSX) expected=artifactflow-xlsx-processor ;;
    DOCX) expected=artifactflow-docx-processor ;;
  esac
  [ -n "$ref" ] || die "$kind is enabled but the pinned release publishes no locked image for it."
  printf '%s\n' "$ref" | grep -Eq "^ghcr\.io/gadsotek/${expected}@sha256:[0-9a-f]{64}$" || \
    die "Invalid immutable $kind processor reference in processor-images.lock."
}

validate_processor_config() {
  config_kind="$1"
  config_lower="$(printf '%s' "$config_kind" | tr '[:upper:]' '[:lower:]')"
  config_file="$CFG/$config_lower-processor.env"
  [ -f "$config_file" ] || die "Missing $config_kind processor environment file."
  config_app_secret="$(read_value "${config_kind}_PROCESSOR_SHARED_SECRET" "$app_env")"
  config_service_secret="$(read_value "${config_kind}_PROCESSOR_SHARED_SECRET" "$config_file")"
  [ -n "$config_app_secret" ] || die "$config_kind app-side processor secret is empty."
  [ "$config_service_secret" = "$config_app_secret" ] || \
    die "$config_kind app and processor secrets do not match."
}

prepare_processor_image() {
  kind="$1"
  require_processor_image "$kind"
  ref="$(processor_image_ref "$kind")"
  local_tag="$(processor_local_tag "$kind")"

  echo "Preparing the pinned $kind processor image..."
  if [ "$no_verify" = "0" ]; then
    gh attestation verify \
      "oci://$ref" \
      --repo Gadsotek/artifactflow \
      --signer-workflow Gadsotek/artifactflow/.github/workflows/release.yml \
      --source-digest "$SOURCE_COMMIT" \
      --predicate-type https://slsa.dev/provenance/v1
  fi
  podman pull "$ref"
  if [ "$kind" = "PDF" ]; then
    podman build -f Dockerfile.pdf-processor \
      --build-arg "PDF_PROCESSOR_IMAGE=$ref" \
      --build-arg "ARTIFACTFLOW_COMMIT=$SOURCE_COMMIT" \
      -t "$local_tag" .
  else
    podman tag "$ref" "$local_tag"
  fi
}

wait_healthy() {
  container="$1"
  attempts="${2:-48}"
  i=0
  while :; do
    status="$(podman inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || echo unknown)"
    if [ "$status" = "healthy" ]; then
      echo "  $container: healthy"
      return 0
    fi
    i=$((i + 1))
    if [ "$i" -ge "$attempts" ]; then
      die "$container did not become healthy (last status: $status). Inspect journalctl --user -u $container"
    fi
    sleep 5
  done
}

if [ "$(id -u)" = "0" ]; then
  die "Run as the artifactflow user, not root."
fi
case "$(uname -s):$(uname -m)" in
  Linux:x86_64) ;;
  *) die "Use a native amd64 Linux systemd host. Processor seccomp checks do not support emulation." ;;
esac
network_backend="$(podman info --format '{{.Host.NetworkBackend}}')" || \
  die "Could not inspect the Podman network backend."
[ "$network_backend" = "netavark" ] || \
  die "The isolated artifact network requires the Podman Netavark backend."
command -v curl >/dev/null 2>&1 || die "curl is required to verify the artifact-host loopback port."
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

cd "$(dirname "$0")"

if [ "$no_pull" = "0" ]; then
  if [ -n "$(git status --porcelain)" ]; then
    die "Working tree is not clean; commit/stash first or use --no-pull."
  fi
  git pull --ff-only
fi

tag="$(sed -n 's/^# Pinned release: ArtifactFlow \(v[0-9.]*\)$/\1/p' quadlet/artifactflow-release.image)"
digest="$(sed -n 's|^Image=ghcr.io/gadsotek/artifactflow@sha256:\([0-9a-f]*\)$|\1|p' quadlet/artifactflow-release.image)"
lock_tag="$(sed -n 's/^# Pinned release: ArtifactFlow \(v[0-9.]*\)$/\1/p' processor-images.lock)"
if [ -z "$tag" ] || [ -z "$digest" ]; then
  die "Could not parse the pinned application release."
fi
[ "$lock_tag" = "$tag" ] || die "Application and processor locks name different releases."
SOURCE_COMMIT="$(sed -n 's/^ARG ARTIFACTFLOW_COMMIT=\([0-9a-f]*\)$/\1/p' Dockerfile.image-parser)"
[ "${#SOURCE_COMMIT}" = "40" ] || die "Invalid pinned release source commit."

echo "Deploying ArtifactFlow $tag (sha256:$digest)"

if [ "$no_verify" = "0" ]; then
  command -v gh >/dev/null 2>&1 || \
    die "GitHub CLI not found. Install gh or use --no-verify only after external verification."
  gh attestation verify \
    "oci://ghcr.io/gadsotek/artifactflow@sha256:$digest" \
    --repo Gadsotek/artifactflow \
    --signer-workflow Gadsotek/artifactflow/.github/workflows/release.yml \
    --source-digest "$SOURCE_COMMIT" \
    --predicate-type https://slsa.dev/provenance/v1
fi

app_env="$CFG/app.env"
[ -f "$app_env" ] || die "Run ./install.sh before deploying."
artifact_url="$(read_value ARTIFACT_URL "$app_env")"
case "$artifact_url" in
  https://*) artifact_host="${artifact_url#https://}"; artifact_host="${artifact_host%%/*}" ;;
  *) die "ARTIFACT_URL must be an HTTPS artifact hostname." ;;
esac
[ -n "$artifact_host" ] || die "ARTIFACT_URL has no artifact hostname."
[ "$(read_value IMAGE_PARSER_SOCKET_PATH "$app_env")" = "/run/artifactflow/image-parser/parser.sock" ] || \
  die "This release requires the image-parser socket. Run ./install.sh --no-admin once; it preserves existing secrets."
pdf_enabled=0
xlsx_enabled=0
docx_enabled=0
reverb_enabled=0
if [ -f "$app_env" ]; then
  [ "$(read_value PDF_PROCESSOR_ENABLED "$app_env")" = "true" ] && pdf_enabled=1
  [ "$(read_value XLSX_PROCESSOR_ENABLED "$app_env")" = "true" ] && xlsx_enabled=1
  [ "$(read_value DOCX_PROCESSOR_ENABLED "$app_env")" = "true" ] && docx_enabled=1
  [ "$(read_value BROADCAST_CONNECTION "$app_env")" = "reverb" ] && reverb_enabled=1
fi
[ "$docx_enabled" = "0" ] || [ "$pdf_enabled" = "1" ] || \
  die "DOCX is enabled without its required PDF processor."

if [ "$pdf_enabled" = "1" ]; then
  validate_processor_config PDF
  require_processor_image PDF
fi
if [ "$xlsx_enabled" = "1" ]; then
  validate_processor_config XLSX
  require_processor_image XLSX
fi
if [ "$docx_enabled" = "1" ]; then
  validate_processor_config DOCX
  require_processor_image DOCX
fi

echo "Building the image parser from the pinned release source..."
podman build -f Dockerfile.image-parser -t localhost/artifactflow-image-parser:pinned .
podman pull "ghcr.io/gadsotek/artifactflow@sha256:$digest"

if [ "$pdf_enabled" = "1" ]; then prepare_processor_image PDF; fi
if [ "$xlsx_enabled" = "1" ]; then prepare_processor_image XLSX; fi
if [ "$docx_enabled" = "1" ]; then prepare_processor_image DOCX; fi

# A failed network preflight must not leave the legacy artifact-host running
# on the application network after this upgrade attempt.
if podman container exists artifactflow-artifact-host; then
  legacy_host_networks="$(podman inspect -f '{{json .NetworkSettings.Networks}}' artifactflow-artifact-host)" || \
    die "Could not inspect the existing artifact-host network attachments."
  if printf '%s\n' "$legacy_host_networks" | grep -Fq '"artifactflow"'; then
    echo "Stopping the legacy artifact-host before isolating its network..."
    systemctl --user stop artifactflow-artifact-host
  fi
else
  exists_status=$?
  [ "$exists_status" = 1 ] || die "Could not check whether a legacy artifact-host container exists."
fi

echo "Installing quadlet units..."
mkdir -p "$HOME/.config/containers/systemd"
for f in quadlet/*; do
  case "$(basename "$f")" in
    artifactflow-pdf-processor.container|artifactflow-pdf-processor-socket-init.container|\
    artifactflow-xlsx-processor.container|artifactflow-xlsx-processor-socket-init.container|\
    artifactflow-docx-processor.container|artifactflow-docx-processor-socket-init.container|\
    artifactflow-reverb.container|\
    artifactflow-pdf.network)
      continue ;;
  esac
  cp "$f" "$HOME/.config/containers/systemd/"
done
if [ "$pdf_enabled" = "1" ]; then
  cp quadlet/artifactflow-pdf-processor.container \
     quadlet/artifactflow-pdf-processor-socket-init.container \
     "$HOME/.config/containers/systemd/"
fi
if [ "$xlsx_enabled" = "1" ]; then
  cp quadlet/artifactflow-xlsx-processor.container \
     quadlet/artifactflow-xlsx-processor-socket-init.container \
     "$HOME/.config/containers/systemd/"
fi
if [ "$docx_enabled" = "1" ]; then
  cp quadlet/artifactflow-docx-processor.container \
     quadlet/artifactflow-docx-processor-socket-init.container \
     "$HOME/.config/containers/systemd/"
fi
if [ "$reverb_enabled" = "1" ]; then
  cp quadlet/artifactflow-reverb.container "$HOME/.config/containers/systemd/"
fi
# Point installed units at $CFG for HOST-side config. Only env-file paths and
# the db-ca Volume source move; the container-side db-ca path and
# DB_SSLROOTCERT stay /etc/artifactflow.
for u in "$HOME/.config/containers/systemd"/*.container; do
  [ -e "$u" ] || continue
  sed -i "s|^EnvironmentFile=/etc/artifactflow/|EnvironmentFile=$CFG/|" "$u"
  sed -i "s|^Volume=/etc/artifactflow/db-ca.pem:|Volume=$CFG/db-ca.pem:|" "$u"
done
systemctl --user daemon-reload
systemctl --user start artifactflow-artifact-network artifactflow-artifact-ingress-network
for network in artifactflow-artifact artifactflow-artifact-ingress; do
  network_internal="$(podman network inspect --format '{{.Internal}}' "$network")" || \
    die "Could not inspect the $network network."
  [ "$network_internal" = "true" ] || \
    die "$network exists without Internal=true; refusing to restart artifact-host."
done

# Older installations have a running PostgreSQL container attached only to
# artifactflow.network. Restart it once with the updated Quadlet before the
# artifact host moves to its isolated, internal network.
postgres_networks="$(podman inspect -f '{{json .NetworkSettings.Networks}}' artifactflow-postgres)" || \
  die "Could not inspect PostgreSQL network attachments."
if ! printf '%s\n' "$postgres_networks" | grep -Fq '"artifactflow-artifact"'; then
  echo "Reattaching PostgreSQL to the isolated artifact network..."
  systemctl --user restart artifactflow-postgres
  wait_healthy artifactflow-postgres
fi
postgres_networks="$(podman inspect -f '{{json .NetworkSettings.Networks}}' artifactflow-postgres)" || \
  die "Could not inspect PostgreSQL network attachments."
printf '%s\n' "$postgres_networks" | grep -Fq '"artifactflow-artifact"' || \
  die "PostgreSQL did not join the isolated artifact database network."

echo "Restarting enabled processors..."
if [ "$pdf_enabled" = "1" ]; then
  systemctl --user start artifactflow-pdf-processor-socket-init
  systemctl --user restart artifactflow-pdf-processor
  wait_healthy artifactflow-pdf-processor
fi
if [ "$xlsx_enabled" = "1" ]; then
  systemctl --user start artifactflow-xlsx-processor-socket-init
  systemctl --user restart artifactflow-xlsx-processor
  wait_healthy artifactflow-xlsx-processor
fi
if [ "$docx_enabled" = "1" ]; then
  systemctl --user start artifactflow-docx-processor-socket-init
  systemctl --user restart artifactflow-docx-processor
  wait_healthy artifactflow-docx-processor
fi

echo "Restarting application services..."
systemctl --user restart artifactflow-image-parser artifactflow-app \
  artifactflow-artifact-host artifactflow-artifact-ingress \
  artifactflow-worker artifactflow-scheduler
host_networks="$(podman inspect -f '{{json .NetworkSettings.Networks}}' artifactflow-artifact-host)" || \
  die "Could not inspect the restarted artifact-host networks."
host_network_count="$(podman inspect -f '{{len .NetworkSettings.Networks}}' artifactflow-artifact-host)" || \
  die "Could not count the restarted artifact-host networks."
if [ "$host_network_count" != 2 ] || \
   ! printf '%s\n' "$host_networks" | grep -Fq '"artifactflow-artifact"' || \
   ! printf '%s\n' "$host_networks" | grep -Fq '"artifactflow-artifact-ingress"'; then
  systemctl --user stop artifactflow-artifact-ingress artifactflow-artifact-host || \
    die "Could not stop the misnetworked artifact-host."
  die "The artifact-host did not start on exactly its two internal networks."
fi
if [ "$reverb_enabled" = "1" ]; then
  systemctl --user restart artifactflow-reverb
fi

echo "Waiting for HTTP surfaces to report healthy..."
wait_healthy artifactflow-app 36
wait_healthy artifactflow-artifact-host 36
wait_healthy artifactflow-artifact-ingress 36
artifact_status="$(curl --noproxy '*' --silent --show-error --max-time 5 \
  --header "Host: $artifact_host" --output /dev/null --write-out '%{http_code}' \
  http://127.0.0.1:8081/login)" || \
  die "The artifact-host loopback port is unreachable from nginx's host."
[ "$artifact_status" = 404 ] || \
  die "The artifact-host relay returned HTTP $artifact_status instead of its expected /login 404."
if [ "$reverb_enabled" = "1" ]; then
  wait_healthy artifactflow-reverb 36
fi

echo
podman exec artifactflow-app php artisan artifactflow:doctor

echo "Deployed $tag."
echo "Reminder: if this release changed docs/operations/artifact-host-database-grants.sql"
echo "(the bump PR body shows the diff), re-apply it: README \"First boot\" step 4."
