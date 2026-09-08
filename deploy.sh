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
# This script never edits /etc/artifactflow. Processor enablement and secrets
# remain installer/operator decisions. If the release changes the restricted
# artifact-host grants, re-apply that manifest after the migration.

no_pull=0
no_verify=0
for arg in "$@"; do
  case "$arg" in
    --no-pull) no_pull=1 ;;
    --no-verify) no_verify=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

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
  config_file="/etc/artifactflow/$config_lower-processor.env"
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

app_env=/etc/artifactflow/app.env
[ -f "$app_env" ] || die "Run ./install.sh before deploying."
[ "$(read_value IMAGE_PARSER_SOCKET_PATH "$app_env")" = "/run/artifactflow/image-parser/parser.sock" ] || \
  die "This release requires the image-parser socket. Run ./install.sh --no-admin once; it preserves existing secrets."
pdf_enabled=0
xlsx_enabled=0
docx_enabled=0
if [ -f "$app_env" ]; then
  [ "$(read_value PDF_PROCESSOR_ENABLED "$app_env")" = "true" ] && pdf_enabled=1
  [ "$(read_value XLSX_PROCESSOR_ENABLED "$app_env")" = "true" ] && xlsx_enabled=1
  [ "$(read_value DOCX_PROCESSOR_ENABLED "$app_env")" = "true" ] && docx_enabled=1
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

echo "Installing quadlet units..."
mkdir -p "$HOME/.config/containers/systemd"
for f in quadlet/*; do
  case "$(basename "$f")" in
    artifactflow-pdf-processor.container|artifactflow-pdf-processor-socket-init.container|\
    artifactflow-xlsx-processor.container|artifactflow-xlsx-processor-socket-init.container|\
    artifactflow-docx-processor.container|artifactflow-docx-processor-socket-init.container|\
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
systemctl --user daemon-reload

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
  artifactflow-artifact-host artifactflow-worker artifactflow-scheduler

echo "Waiting for HTTP surfaces to report healthy..."
wait_healthy artifactflow-app 36
wait_healthy artifactflow-artifact-host 36

echo
podman exec artifactflow-app php artisan artifactflow:doctor

echo "Deployed $tag."
echo "Reminder: if this release changed docs/operations/artifact-host-database-grants.sql"
echo "(the bump PR body shows the diff), re-apply it: README \"First boot\" step 4."
