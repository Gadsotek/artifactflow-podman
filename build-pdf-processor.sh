#!/usr/bin/env bash
set -euo pipefail

# Build the PDF processor image (Java/PDFBox) from the pinned release source.
#
# PDF is optional and default-off. You only need this image if you enable PDF
# artifacts (see README "PDF uploads"), and enabling PDF in production requires
# completing the per-deployment production-enablement gate in the release's
# RELEASE-CHECKLIST.md first.
#
# This reuses the release's own pdf-processor Dockerfile verbatim (it pins the
# PDFBox version and SHA-512), so this repo carries no copy of that build and
# cannot drift from it. The pinned commit is read from Dockerfile.image-parser
# so both local components track the same release.
#
# Build on the VM:
#   ./build-pdf-processor.sh

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

command -v podman >/dev/null 2>&1 || { echo "podman not found." >&2; exit 1; }
command -v curl   >/dev/null 2>&1 || { echo "curl not found." >&2; exit 1; }

COMMIT="$(sed -n 's/^ARG ARTIFACTFLOW_COMMIT=\([0-9a-f]*\)$/\1/p' Dockerfile.image-parser)"
[ -n "$COMMIT" ] || { echo "Could not read the pinned commit from Dockerfile.image-parser." >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Fetching ArtifactFlow source at ${COMMIT}..."
curl -fsSL "https://github.com/Gadsotek/artifactflow/archive/${COMMIT}.tar.gz" -o "$tmp/src.tgz"
tar -xzf "$tmp/src.tgz" -C "$tmp"

ctx="$tmp/artifactflow-${COMMIT}/pdf-processor-spike"
[ -d "$ctx" ] || { echo "pdf-processor-spike/ not found in the release source." >&2; exit 1; }

echo "Building the PDF processor (Java + PDFBox, downloads dependencies, takes a while)..."
podman build \
  -f "$ctx/Dockerfile" \
  --target pdf-processor-service \
  -t localhost/artifactflow-pdf-processor:pinned \
  "$ctx"

echo "Built localhost/artifactflow-pdf-processor:pinned"
