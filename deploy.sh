#!/bin/sh
set -eu

# Apply the committed deployment state of this repository to the local VM.
#
# Run on the VM as the artifactflow user, from the repo clone:
#   ./deploy.sh              pull, verify attestation, rebuild parser, restart
#   ./deploy.sh --no-pull    deploy the working tree as-is (no git pull)
#   ./deploy.sh --no-verify  skip attestation verification; use only when the
#                            digest PR was already verified in CI and gh is
#                            not installed on this VM
#
# This script deploys only what is committed here: the digest pin, the parser
# source pin, and the quadlet units. It never edits /etc/artifactflow. If the
# release changed docs/operations/artifact-host-database-grants.sql, apply the
# new manifest manually (README "First boot" step 4); this script reminds you
# but cannot decide for you.

no_pull=0
no_verify=0
for arg in "$@"; do
  case "$arg" in
    --no-pull) no_pull=1 ;;
    --no-verify) no_verify=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" = "0" ]; then
  echo "Run as the artifactflow user, not root." >&2
  exit 1
fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

cd "$(dirname "$0")"

if [ "$no_pull" = "0" ]; then
  if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree is not clean; commit/stash first or use --no-pull." >&2
    exit 1
  fi
  git pull --ff-only
fi

tag="$(sed -n 's/^# Pinned release: ArtifactFlow \(v[0-9.]*\)$/\1/p' quadlet/artifactflow-release.image)"
digest="$(sed -n 's|^Image=ghcr.io/gadsotek/artifactflow@sha256:\([0-9a-f]*\)$|\1|p' quadlet/artifactflow-release.image)"
if [ -z "$tag" ] || [ -z "$digest" ]; then
  echo "Could not parse the pinned tag/digest from quadlet/artifactflow-release.image." >&2
  exit 1
fi
echo "Deploying ArtifactFlow $tag (sha256:$digest)"

if [ "$no_verify" = "0" ]; then
  if command -v gh >/dev/null 2>&1; then
    gh attestation verify \
      "oci://ghcr.io/gadsotek/artifactflow@sha256:$digest" \
      --repo Gadsotek/artifactflow \
      --signer-workflow Gadsotek/artifactflow/.github/workflows/release.yml \
      --predicate-type https://slsa.dev/provenance/v1
  else
    echo "GitHub CLI not found: cannot verify the image attestation here." >&2
    echo "Install gh, or re-run with --no-verify if the digest PR was verified in CI." >&2
    exit 1
  fi
fi

# PDF is opt-in; only touch its image/units if this deployment enabled it.
pdf_enabled=0
if [ -f /etc/artifactflow/app.env ] && \
   [ "$(sed -n 's/^PDF_PROCESSOR_ENABLED=//p' /etc/artifactflow/app.env | head -n1)" = "true" ]; then
  pdf_enabled=1
fi

echo "Building the image parser from the pinned release source..."
podman build -f Dockerfile.image-parser -t localhost/artifactflow-image-parser:pinned .

if [ "$pdf_enabled" = "1" ]; then
  echo "Building the PDF processor from the pinned release source..."
  ./build-pdf-processor.sh
fi

echo "Installing quadlet units..."
mkdir -p "$HOME/.config/containers/systemd"
for f in quadlet/*; do
  case "$(basename "$f")" in
    artifactflow-pdf-processor.container|artifactflow-pdf-processor-socket-init.container|artifactflow-pdf.network)
      continue ;;
  esac
  cp "$f" "$HOME/.config/containers/systemd/"
done
if [ "$pdf_enabled" = "1" ]; then
  cp quadlet/artifactflow-pdf-processor.container \
     quadlet/artifactflow-pdf-processor-socket-init.container \
     "$HOME/.config/containers/systemd/"
fi
systemctl --user daemon-reload

echo "Restarting services..."
if [ "$pdf_enabled" = "1" ]; then
  systemctl --user start artifactflow-pdf-processor-socket-init
  systemctl --user restart artifactflow-pdf-processor
fi
systemctl --user restart artifactflow-image-parser artifactflow-app \
  artifactflow-artifact-host artifactflow-worker artifactflow-scheduler

echo "Waiting for HTTP surfaces to report healthy..."
for c in artifactflow-app artifactflow-artifact-host; do
  i=0
  while :; do
    status="$(podman inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo unknown)"
    [ "$status" = "healthy" ] && break
    i=$((i + 1))
    if [ "$i" -ge 36 ]; then
      echo "$c did not become healthy (last status: $status)." >&2
      echo "Inspect with: journalctl --user -u $c" >&2
      exit 1
    fi
    sleep 5
  done
  echo "  $c: healthy"
done

echo
echo "Deployed $tag."
echo "Reminder: if this release changed docs/operations/artifact-host-database-grants.sql"
echo "(the bump PR body shows the diff), re-apply it: README \"First boot\" step 4."
