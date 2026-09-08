#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [ -f "$root/$1" ] || fail "missing $1"
}

assert_contains() {
  local file="$1" expected="$2"
  grep -F -- "$expected" "$root/$file" >/dev/null || \
    fail "$file does not contain: $expected"
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  if grep -F -- "$unexpected" "$root/$file" >/dev/null; then
    fail "$file unexpectedly contains: $unexpected"
  fi
}

read_setting() {
  sed -n "s|^$1=||p" "$root/$2" | head -n1
}

bash -n "$root/install.sh"
sh -n "$root/deploy.sh"

assert_file processor-images.lock
assert_contains processor-images.lock 'PDF_PROCESSOR_IMAGE=ghcr.io/gadsotek/artifactflow-pdf-processor@sha256:'
assert_contains processor-images.lock 'XLSX_PROCESSOR_IMAGE='
assert_contains processor-images.lock 'DOCX_PROCESSOR_IMAGE='

app_tag="$(sed -n 's/^# Pinned release: ArtifactFlow \(v[0-9.]*\)$/\1/p' "$root/quadlet/artifactflow-release.image")"
lock_tag="$(sed -n 's/^# Pinned release: ArtifactFlow \(v[0-9.]*\)$/\1/p' "$root/processor-images.lock")"
if [ -z "$app_tag" ] || [ "$app_tag" != "$lock_tag" ]; then
  fail 'release lock tags differ'
fi

pdf_ref="$(read_setting PDF_PROCESSOR_IMAGE processor-images.lock)"
printf '%s\n' "$pdf_ref" | grep -Eq '^ghcr\.io/gadsotek/artifactflow-pdf-processor@sha256:[0-9a-f]{64}$' || \
  fail 'PDF processor is not pinned by immutable digest'
xlsx_ref="$(read_setting XLSX_PROCESSOR_IMAGE processor-images.lock)"
if [ -n "$xlsx_ref" ]; then
  printf '%s\n' "$xlsx_ref" | grep -Eq '^ghcr\.io/gadsotek/artifactflow-xlsx-processor@sha256:[0-9a-f]{64}$' || \
    fail 'XLSX processor is not pinned by immutable digest'
fi
docx_ref="$(read_setting DOCX_PROCESSOR_IMAGE processor-images.lock)"
if [ -n "$docx_ref" ]; then
  printf '%s\n' "$docx_ref" | grep -Eq '^ghcr\.io/gadsotek/artifactflow-docx-processor@sha256:[0-9a-f]{64}$' || \
    fail 'DOCX processor is not pinned by immutable digest'
fi

assert_contains install.sh '--enable-pdf'
assert_contains install.sh '--enable-xlsx'
assert_contains install.sh '--enable-docx'
assert_contains install.sh 'DOCX requires PDF; enabling both.'
assert_contains install.sh 'prepare_processor_image PDF'
assert_contains install.sh 'prepare_processor_image XLSX'
assert_contains install.sh 'prepare_processor_image DOCX'
assert_not_contains install.sh 'build-pdf-processor.sh'
assert_not_contains install.sh "artifactflow:doctor' || true"

assert_file env/xlsx-processor.env.example
assert_file env/docx-processor.env.example
assert_contains env/app.env.example 'XLSX_PROCESSOR_ENABLED=false'
assert_contains env/app.env.example 'DOCX_PROCESSOR_ENABLED=false'
assert_contains env/xlsx-processor.env.example 'XLSX_PROCESSOR_SHARED_SECRET='
assert_contains env/docx-processor.env.example 'DOCX_PROCESSOR_SHARED_SECRET='

assert_file quadlet/artifactflow-xlsx-processor.container
assert_file quadlet/artifactflow-xlsx-processor-socket-init.container
assert_file quadlet/artifactflow-docx-processor.container
assert_file quadlet/artifactflow-docx-processor-socket-init.container
assert_contains quadlet/artifactflow-app.container 'Volume=artifactflow-xlsx-socket:/run/artifactflow/xlsx-processor:ro'
assert_contains quadlet/artifactflow-app.container 'Volume=artifactflow-docx-socket:/run/artifactflow/docx-processor:ro'
assert_contains quadlet/artifactflow-artifact-host.container 'XLSX_PROCESSOR_URL='
assert_contains quadlet/artifactflow-artifact-host.container 'DOCX_PROCESSOR_URL='
assert_contains quadlet/artifactflow-worker.container 'XLSX_PROCESSOR_ENABLED=false'
assert_contains quadlet/artifactflow-worker.container 'DOCX_PROCESSOR_ENABLED=false'
assert_contains quadlet/artifactflow-scheduler.container 'XLSX_PROCESSOR_ENABLED=false'
assert_contains quadlet/artifactflow-scheduler.container 'DOCX_PROCESSOR_ENABLED=false'

assert_contains quadlet/artifactflow-xlsx-processor.container 'Network=none'
assert_contains quadlet/artifactflow-xlsx-processor.container 'RequiredBy=artifactflow-app.service'
assert_contains quadlet/artifactflow-xlsx-processor.container 'PidsLimit=32'
assert_contains quadlet/artifactflow-xlsx-processor.container 'PodmanArgs=--memory=384m --cpus=1.0'
assert_contains quadlet/artifactflow-pdf-processor.container 'PodmanArgs=--memory=512m --cpus=1.0'
assert_contains quadlet/artifactflow-docx-processor.container 'Network=none'
assert_contains quadlet/artifactflow-docx-processor.container 'RequiredBy=artifactflow-app.service'
assert_contains quadlet/artifactflow-docx-processor.container 'PidsLimit=128'
assert_contains quadlet/artifactflow-docx-processor.container 'PodmanArgs=--memory=768m --cpus=1.0'
assert_contains quadlet/artifactflow-docx-processor.container 'Ulimit=nofile=256:256'

assert_contains deploy.sh 'prepare_processor_image PDF'
assert_contains deploy.sh 'prepare_processor_image XLSX'
assert_contains deploy.sh 'prepare_processor_image DOCX'
assert_contains deploy.sh 'validate_processor_config PDF'
assert_contains deploy.sh 'validate_processor_config XLSX'
assert_contains deploy.sh 'validate_processor_config DOCX'
assert_contains .github/workflows/release-watch.yml 'artifactflow-xlsx-processor@sha256:'
assert_contains .github/workflows/release-watch.yml 'artifactflow-docx-processor@sha256:'

echo 'processor install contract: OK'
