#!/usr/bin/env bash
set -euo pipefail

# ArtifactFlow · guided installer for a single server (rootless Podman).
#
# Run as the `artifactflow` user from a clone of this repository:
#   ./install.sh
#
# The script asks for your two hostnames and mail transport, generates all
# secrets, builds the deployment-local images, pulls enabled processor images
# by release digest, starts services in the correct order,
# runs the first migration, creates the restricted artifact-host database role,
# and (optionally) creates the first administrator. At the end it prints the
# remaining root steps (nginx + HTTPS).
#
# What the script does NOT do (a human must): the two DNS records and
# nginx + certbot. It prints the exact commands at the end.
#
# Flags:
#   --reconfigure   REGENERATE all configuration and secrets in /etc/artifactflow.
#                   This rotates APP_KEY, which makes existing encrypted data and
#                   2FA unrecoverable. Use only on a fresh/empty installation.
#   --enable-pdf    enable PDF without rotating unrelated secrets
#   --enable-xlsx   enable XLSX without rotating unrelated secrets
#   --enable-docx   enable DOCX and its required PDF chain without rotating
#                   unrelated secrets
#   --no-admin      skip creating the first administrator

RECONFIGURE=0
CREATE_ADMIN=1
ENABLE_PDF=0
ENABLE_XLSX=0
ENABLE_DOCX=0
for arg in "$@"; do
  case "$arg" in
    --reconfigure) RECONFIGURE=1 ;;
    --enable-pdf) ENABLE_PDF=1 ;;
    --enable-xlsx) ENABLE_XLSX=1 ;;
    --enable-docx) ENABLE_DOCX=1 ;;
    --no-admin) CREATE_ADMIN=0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

CFG=/etc/artifactflow
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

# ---------- helpers ----------
die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
gen_secret() { openssl rand -base64 32; }

# set KEY=VALUE in a file (replace the existing line, otherwise append)
set_env() {
  local key="$1" val="$2" file="$3" esc
  esc=$(printf '%s' "$val" | sed -e 's/[\\&|]/\\&/g')
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${esc}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

# read the value of KEY from an env file (everything after the first =)
read_env() { sed -n "s|^$1=||p" "$2" | head -n1; }

processor_image_ref() {
  case "$1" in
    PDF) read_env PDF_PROCESSOR_IMAGE processor-images.lock ;;
    XLSX) read_env XLSX_PROCESSOR_IMAGE processor-images.lock ;;
    DOCX) read_env DOCX_PROCESSOR_IMAGE processor-images.lock ;;
    *) die "Unknown processor: $1" ;;
  esac
}

processor_local_tag() {
  case "$1" in
    PDF) printf '%s\n' localhost/artifactflow-pdf-processor:pinned ;;
    XLSX) printf '%s\n' localhost/artifactflow-xlsx-processor:pinned ;;
    DOCX) printf '%s\n' localhost/artifactflow-docx-processor:pinned ;;
    *) die "Unknown processor: $1" ;;
  esac
}

processor_image_available() {
  [ -n "$(processor_image_ref "$1")" ]
}

require_processor_image() {
  local kind="$1" ref expected
  ref="$(processor_image_ref "$kind")"
  case "$kind" in
    PDF) expected=artifactflow-pdf-processor ;;
    XLSX) expected=artifactflow-xlsx-processor ;;
    DOCX) expected=artifactflow-docx-processor ;;
  esac
  [ -n "$ref" ] || die "$kind is unavailable in pinned release $TAG; keep it disabled until processor-images.lock is populated by a release bump."
  [[ "$ref" =~ ^ghcr\.io/gadsotek/${expected}@sha256:[0-9a-f]{64}$ ]] || \
    die "Invalid immutable $kind processor reference in processor-images.lock."
}

prepare_processor_image() {
  local kind="$1" ref local_tag
  require_processor_image "$kind"
  ref="$(processor_image_ref "$kind")"
  local_tag="$(processor_local_tag "$kind")"

  echo "== Preparing the pinned $kind processor image..."
  if have gh; then
    gh attestation verify \
      "oci://$ref" \
      --repo Gadsotek/artifactflow \
      --signer-workflow Gadsotek/artifactflow/.github/workflows/release.yml \
      --source-digest "$SOURCE_COMMIT" \
      --predicate-type https://slsa.dev/provenance/v1 \
      || die "$kind processor attestation verification failed. Do not deploy it."
  else
    echo "   !! gh not found: verify $ref from a trusted workstation before enabling $kind."
  fi

  podman pull "$ref" || die "Could not pull the pinned $kind processor image."
  if [ "$kind" = "PDF" ]; then
    podman build -f Dockerfile.pdf-processor \
      --build-arg "PDF_PROCESSOR_IMAGE=$ref" \
      --build-arg "ARTIFACTFLOW_COMMIT=$SOURCE_COMMIT" \
      -t "$local_tag" .
  else
    podman tag "$ref" "$local_tag"
  fi
}

ensure_processor_env() {
  local kind="$1" lower
  lower="$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')"
  if [ ! -f "$CFG/$lower-processor.env" ]; then
    install -m 0600 "env/$lower-processor.env.example" "$CFG/$lower-processor.env"
  fi
}

enable_processor_config() {
  local kind="$1" secret lower
  require_processor_image "$kind"
  ensure_processor_env "$kind"
  lower="$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')"
  secret="$(gen_secret)"
  set_env "${kind}_PROCESSOR_ENABLED" "true" "$CFG/app.env"
  set_env "${kind}_PROCESSOR_URL" "http://localhost" "$CFG/app.env"
  set_env "${kind}_PROCESSOR_SOCKET_PATH" "/run/artifactflow/$lower-processor/processor.sock" "$CFG/app.env"
  set_env "${kind}_PROCESSOR_SHARED_SECRET" "$secret" "$CFG/app.env"
  set_env "${kind}_PROCESSOR_SHARED_SECRET" "$secret" "$CFG/$lower-processor.env"
}

sync_processor_env() {
  local kind="$1" secret lower
  ensure_processor_env "$kind"
  lower="$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')"
  secret="$(read_env "${kind}_PROCESSOR_SHARED_SECRET" "$CFG/app.env")"
  [ -n "$secret" ] || die "$kind is enabled but its app-side shared secret is empty."
  set_env "${kind}_PROCESSOR_SHARED_SECRET" "$secret" "$CFG/$lower-processor.env"
}

# wait until a container reports "healthy"
wait_healthy() {
  local c="$1" tries="${2:-48}" i=0 st
  printf '  waiting for %s ' "$c"
  while :; do
    st=$(podman inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo unknown)
    if [ "$st" = healthy ]; then printf ' OK\n'; return 0; fi
    i=$((i + 1))
    if [ "$i" -ge "$tries" ]; then
      printf ' still "%s"\n' "$st"
      echo "  Check: journalctl --user -u $c" >&2
      return 1
    fi
    printf '.'; sleep 5
  done
}

prompt() { # prompt VARNAME "question" "default"
  local __var="$1" __q="$2" __def="${3:-}" __ans
  if [ -n "$__def" ]; then
    read -r -p "$__q [$__def]: " __ans || true
    __ans="${__ans:-$__def}"
  else
    read -r -p "$__q: " __ans || true
  fi
  printf -v "$__var" '%s' "$__ans"
}

prompt_host() { # prompt_host VARNAME "question", required, no default, validated
  local __var="$1" __q="$2" __ans
  while :; do
    read -r -p "$__q: " __ans || true
    __ans="${__ans#http://}"; __ans="${__ans#https://}"; __ans="${__ans%%/*}"
    __ans="$(printf '%s' "$__ans" | tr -d '[:space:]')"
    [ -z "$__ans" ] && { echo "  Enter a hostname (there is deliberately no default)."; continue; }
    case "$__ans" in
      *.*) : ;;
      *) echo "  That does not look like a hostname (no dot)."; continue ;;
    esac
    case "$__ans" in
      *example.com|*example.org|*example.net|localhost)
        echo "  Do not use a placeholder, enter your real hostname."; continue ;;
    esac
    break
  done
  printf -v "$__var" '%s' "$__ans"
}

prompt_secret() { # prompt_secret VARNAME "question"
  local __var="$1" __q="$2" __a1 __a2
  while :; do
    read -r -s -p "$__q: " __a1; echo
    read -r -s -p "$__q (again): " __a2; echo
    [ "$__a1" = "$__a2" ] && break
    echo "  Values do not match, try again."
  done
  printf -v "$__var" '%s' "$__a1"
}

# ---------- 0) environment checks ----------
echo "== ArtifactFlow installer =="
[ "$(id -u)" = "0" ] && die "Run as the 'artifactflow' user, not root."
case "$(uname -s):$(uname -m)" in
  Linux:x86_64) ;;
  *) die "Use a native amd64 Linux systemd host. Processor seccomp checks do not support emulation." ;;
esac
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
have podman  || die "podman not found (Podman 5.0+). Install it as root: apt install podman"
have openssl || die "openssl not found."
[ -d "$CFG" ] || die "Directory $CFG does not exist. Create it as root (see GUIDE.html, step 0)."
[ -w "$CFG" ] || die "Cannot write to $CFG. Make sure it is owned by the artifactflow user."
have curl || echo "Note: curl not found. You will have to apply the database grants manually (shown at the end)."

TAG="$(sed -n 's/^# Pinned release: ArtifactFlow \(v[0-9.]*\)$/\1/p' quadlet/artifactflow-release.image)"
DIGEST="$(sed -n 's|^Image=ghcr.io/gadsotek/artifactflow@sha256:\([0-9a-f]*\)$|\1|p' quadlet/artifactflow-release.image)"
[ -n "$TAG" ] && [ -n "$DIGEST" ] || die "Could not read version/digest from quadlet/artifactflow-release.image."
LOCK_TAG="$(sed -n 's/^# Pinned release: ArtifactFlow \(v[0-9.]*\)$/\1/p' processor-images.lock)"
[ "$LOCK_TAG" = "$TAG" ] || die "Application and processor image locks name different releases."
echo "Version: $TAG"

SOURCE_COMMIT="$(sed -n 's/^ARG ARTIFACTFLOW_COMMIT=\([0-9a-f]*\)$/\1/p' Dockerfile.image-parser)"
[ "${#SOURCE_COMMIT}" = "40" ] || die "Invalid pinned release source commit."

# ---------- 1) configuration ----------
PDF_ENABLED=0
XLSX_ENABLED=0
DOCX_ENABLED=0
if [ -f "$CFG/app.env" ] && [ "$RECONFIGURE" = "0" ]; then
  echo
  echo "== Configuration already exists in $CFG, keeping it (and all secrets)."
  echo "   Enable formats with --enable-pdf, --enable-xlsx, or --enable-docx."
  CREATE_ADMIN=0
  APP_HOST="$(read_env APP_URL "$CFG/app.env" | sed 's#^https\?://##')"
  ART_HOST="$(read_env ARTIFACT_URL "$CFG/app.env" | sed 's#^https\?://##')"
  [ "$(read_env PDF_PROCESSOR_ENABLED "$CFG/app.env")" = "true" ] && PDF_ENABLED=1
  [ "$(read_env XLSX_PROCESSOR_ENABLED "$CFG/app.env")" = "true" ] && XLSX_ENABLED=1
  [ "$(read_env DOCX_PROCESSOR_ENABLED "$CFG/app.env")" = "true" ] && DOCX_ENABLED=1

  if [ "$ENABLE_DOCX" = "1" ] && [ "$PDF_ENABLED" = "0" ]; then
    echo "== DOCX requires PDF; enabling both."
    ENABLE_PDF=1
  fi

  [ "$ENABLE_PDF" = "0" ] || [ "$PDF_ENABLED" = "1" ] || require_processor_image PDF
  [ "$ENABLE_XLSX" = "0" ] || [ "$XLSX_ENABLED" = "1" ] || require_processor_image XLSX
  [ "$ENABLE_DOCX" = "0" ] || [ "$DOCX_ENABLED" = "1" ] || require_processor_image DOCX

  if [ "$ENABLE_PDF" = "1" ] && [ "$PDF_ENABLED" = "0" ]; then
    echo "== Enabling PDF (other secrets untouched)."
    enable_processor_config PDF
    PDF_ENABLED=1
  fi
  if [ "$ENABLE_XLSX" = "1" ] && [ "$XLSX_ENABLED" = "0" ]; then
    echo "== Enabling XLSX (other secrets untouched)."
    enable_processor_config XLSX
    XLSX_ENABLED=1
  fi
  if [ "$ENABLE_DOCX" = "1" ] && [ "$DOCX_ENABLED" = "0" ]; then
    echo "== Enabling DOCX (other secrets untouched)."
    enable_processor_config DOCX
    DOCX_ENABLED=1
  fi

  [ "$DOCX_ENABLED" = "0" ] || [ "$PDF_ENABLED" = "1" ] || \
    die "DOCX_PROCESSOR_ENABLED=true requires PDF_PROCESSOR_ENABLED=true."
else
  echo
  echo "== Configuration: a few questions. Enter accepts the value in brackets."
  echo
  echo "The app and the artifacts MUST run on two different hostnames (isolation)."
  echo "There are deliberately no defaults so you cannot deploy someone else's host."
  prompt_host APP_HOST "App hostname (e.g. artifactflow.yourcompany.com)"
  prompt_host ART_HOST "Artifact hostname, DIFFERENT (e.g. artifacts.yourcompany.com)"
  [ "$APP_HOST" = "$ART_HOST" ] && die "The two hostnames must differ."
  echo "  -> app:       https://$APP_HOST"
  echo "  -> artifacts: https://$ART_HOST"

  echo
  echo "Mail delivery (invitations, password resets). Production will not boot without it."
  prompt MAIL_KIND "Mail transport: smtp or resend" "smtp"

  # secrets
  APP_KEY_VAL="base64:$(gen_secret)"
  SIGN_KEY_VAL="base64:$(gen_secret)"
  DB_PW="$(gen_secret)"
  PARSER_SECRET="$(gen_secret)"
  ARTHOST_DB_PW="$(gen_secret)"

  umask 077
  install -m 0600 env/app.env.example           "$CFG/app.env"
  install -m 0600 env/postgres.env.example      "$CFG/postgres.env"
  install -m 0600 env/parser.env.example        "$CFG/parser.env"
  install -m 0600 env/artifact-host.env.example "$CFG/artifact-host.env"

  # app.env
  set_env APP_KEY "$APP_KEY_VAL" "$CFG/app.env"
  set_env APP_URL "https://$APP_HOST" "$CFG/app.env"
  set_env ARTIFACT_URL "https://$ART_HOST" "$CFG/app.env"
  set_env ARTIFACT_FRAME_ANCESTORS "https://$APP_HOST" "$CFG/app.env"
  set_env ARTIFACT_URL_SIGNING_KEY "$SIGN_KEY_VAL" "$CFG/app.env"
  set_env DB_PASSWORD "$DB_PW" "$CFG/app.env"
  set_env IMAGE_PARSER_SHARED_SECRET "$PARSER_SECRET" "$CFG/app.env"

  # postgres.env + parser.env + artifact-host.env
  set_env POSTGRES_PASSWORD "$DB_PW" "$CFG/postgres.env"
  set_env IMAGE_PARSER_SHARED_SECRET "$PARSER_SECRET" "$CFG/parser.env"
  set_env DB_PASSWORD "$ARTHOST_DB_PW" "$CFG/artifact-host.env"

  # mail
  if [ "$MAIL_KIND" = "resend" ]; then
    prompt_secret RESEND_KEY "Resend API key"
    prompt MAIL_FROM "From address" "no-reply@$APP_HOST"
    set_env MAIL_MAILER "resend" "$CFG/app.env"
    set_env RESEND_KEY "$RESEND_KEY" "$CFG/app.env"
    set_env MAIL_FROM_ADDRESS "$MAIL_FROM" "$CFG/app.env"
  else
    prompt MAIL_HOST_V "SMTP host" ""
    prompt MAIL_PORT_V "SMTP port" "587"
    prompt MAIL_USER_V "SMTP username" ""
    prompt_secret MAIL_PASS_V "SMTP password"
    prompt MAIL_ENC_V "Encryption (tls/ssl)" "tls"
    prompt MAIL_FROM "From address" "no-reply@$APP_HOST"
    set_env MAIL_MAILER "smtp" "$CFG/app.env"
    set_env MAIL_HOST "$MAIL_HOST_V" "$CFG/app.env"
    set_env MAIL_PORT "$MAIL_PORT_V" "$CFG/app.env"
    set_env MAIL_USERNAME "$MAIL_USER_V" "$CFG/app.env"
    set_env MAIL_PASSWORD "$MAIL_PASS_V" "$CFG/app.env"
    set_env MAIL_ENCRYPTION "$MAIL_ENC_V" "$CFG/app.env"
    set_env MAIL_FROM_ADDRESS "$MAIL_FROM" "$CFG/app.env"
  fi

  # Document processors are optional and off by default. Each enabled format is
  # still subject to its deployment-specific production gate after install.
  echo
  echo "Available PDF, XLSX, and DOCX capabilities are OFF by default. Enabling"
  echo "a published format wires its networkless Unix-socket processor; TESTING.md still"
  echo "requires containment, doctor, browser, image, and final-review evidence."

  if [ "$ENABLE_PDF" = "1" ]; then
    PDF_ENABLED=1
  else
    prompt PDF_KIND "Enable PDF artifacts now? (y/N)" "N"
    case "$PDF_KIND" in [Yy]*) PDF_ENABLED=1 ;; esac
  fi

  if [ "$ENABLE_XLSX" = "1" ]; then
    XLSX_ENABLED=1
  elif processor_image_available XLSX; then
    prompt XLSX_KIND "Enable XLSX artifacts now? (y/N)" "N"
    case "$XLSX_KIND" in [Yy]*) XLSX_ENABLED=1 ;; esac
  else
    echo "  XLSX unavailable in pinned release $TAG; keeping it off."
  fi

  if [ "$ENABLE_DOCX" = "1" ]; then
    DOCX_ENABLED=1
  elif processor_image_available DOCX; then
    prompt DOCX_KIND "Enable DOCX artifacts now? (y/N)" "N"
    case "$DOCX_KIND" in [Yy]*) DOCX_ENABLED=1 ;; esac
  else
    echo "  DOCX unavailable in pinned release $TAG; keeping it off."
  fi

  if [ "$DOCX_ENABLED" = "1" ] && [ "$PDF_ENABLED" = "0" ]; then
    echo "  DOCX requires PDF; enabling both."
    PDF_ENABLED=1
  fi

  # Validate the complete selected chain before changing any feature flag.
  if [ "$PDF_ENABLED" = "1" ]; then require_processor_image PDF; fi
  if [ "$XLSX_ENABLED" = "1" ]; then require_processor_image XLSX; fi
  if [ "$DOCX_ENABLED" = "1" ]; then require_processor_image DOCX; fi

  if [ "$PDF_ENABLED" = "1" ]; then
    enable_processor_config PDF
    echo "  PDF enabled."
  else
    echo "  PDF left off; enable later with ./install.sh --enable-pdf"
  fi
  if [ "$XLSX_ENABLED" = "1" ]; then
    enable_processor_config XLSX
    echo "  XLSX enabled."
  else
    echo "  XLSX left off; enable later with ./install.sh --enable-xlsx"
  fi
  if [ "$DOCX_ENABLED" = "1" ]; then
    enable_processor_config DOCX
    echo "  DOCX enabled with its required PDF chain."
  else
    echo "  DOCX left off; enable later with ./install.sh --enable-docx"
  fi

  echo
  echo "== Secrets generated and written to $CFG (mode 0600)."
  echo "   IMPORTANT: copy APP_KEY and ARTIFACT_URL_SIGNING_KEY from $CFG/app.env"
  echo "   into a password manager. They are in no backup, and losing APP_KEY makes"
  echo "   encrypted data and 2FA unrecoverable."
fi

[ -n "$APP_HOST" ] && [ -n "$ART_HOST" ] || die "Could not determine the hostnames."

# v0.2.1 uses the local image parser socket; preserve the existing HMAC secret.
set_env IMAGE_PARSER_URL "http://localhost" "$CFG/app.env"
set_env IMAGE_PARSER_SOCKET_PATH "/run/artifactflow/image-parser/parser.sock" "$CFG/app.env"

if [ "$PDF_ENABLED" = "1" ]; then
  require_processor_image PDF
  sync_processor_env PDF
fi
if [ "$XLSX_ENABLED" = "1" ]; then
  require_processor_image XLSX
  sync_processor_env XLSX
fi
if [ "$DOCX_ENABLED" = "1" ]; then
  [ "$PDF_ENABLED" = "1" ] || die "DOCX requires the PDF processor."
  require_processor_image DOCX
  sync_processor_env DOCX
fi

# ---------- 2) local infrastructure images + pinned release images ----------
echo
echo "== Building the database image and the image parser (this takes a while)..."
podman build -f Dockerfile.postgres     -t localhost/artifactflow-postgres:17 .
podman build -f Dockerfile.image-parser -t localhost/artifactflow-image-parser:pinned .

echo "== Pulling the application image $TAG from GHCR..."
if have gh; then
  echo "   Verifying build provenance (attestation)..."
  gh attestation verify \
    "oci://ghcr.io/gadsotek/artifactflow@sha256:$DIGEST" \
    --repo Gadsotek/artifactflow \
    --signer-workflow Gadsotek/artifactflow/.github/workflows/release.yml \
    --source-digest "$SOURCE_COMMIT" \
    --predicate-type https://slsa.dev/provenance/v1 \
    || die "Attestation verification failed for the pinned digest. Do not deploy it."
else
  echo "   !! GitHub CLI (gh) not found: skipping attestation verification here."
  echo "      Verify the pinned digest's provenance elsewhere (see README, Prerequisites)."
fi
podman pull "ghcr.io/gadsotek/artifactflow@sha256:$DIGEST" || \
  echo "  (the pull will be retried when the service starts)"

if [ "$PDF_ENABLED" = "1" ]; then prepare_processor_image PDF; fi
if [ "$XLSX_ENABLED" = "1" ]; then prepare_processor_image XLSX; fi
if [ "$DOCX_ENABLED" = "1" ]; then prepare_processor_image DOCX; fi

# ---------- 3) quadlet units ----------
echo "== Installing quadlet units..."
mkdir -p "$HOME/.config/containers/systemd"
# Copy base units first. Processor units are installed only for formats that
# were explicitly enabled, so disabled services do not exist on the VM.
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
if [ "$PDF_ENABLED" = "1" ]; then
  cp quadlet/artifactflow-pdf-processor.container \
     quadlet/artifactflow-pdf-processor-socket-init.container \
     "$HOME/.config/containers/systemd/"
fi
if [ "$XLSX_ENABLED" = "1" ]; then
  cp quadlet/artifactflow-xlsx-processor.container \
     quadlet/artifactflow-xlsx-processor-socket-init.container \
     "$HOME/.config/containers/systemd/"
fi
if [ "$DOCX_ENABLED" = "1" ]; then
  cp quadlet/artifactflow-docx-processor.container \
     quadlet/artifactflow-docx-processor-socket-init.container \
     "$HOME/.config/containers/systemd/"
fi
systemctl --user daemon-reload

# ---------- 4) database + CA ----------
echo
echo "== Starting the database..."
systemctl --user start artifactflow-postgres
wait_healthy artifactflow-postgres || die "The database did not come up."

echo "== Extracting the database CA certificate..."
podman exec artifactflow-postgres \
  cat /var/lib/postgresql/data/certs/root.crt > "$CFG/db-ca.pem"
chmod 0644 "$CFG/db-ca.pem"

# ---------- 5) app + parser + first migration ----------
echo "== Starting storage-init, parser, and the app..."
systemctl --user start artifactflow-storage-init
systemctl --user restart artifactflow-image-parser
if [ "$PDF_ENABLED" = "1" ]; then
  echo "== Starting the PDF processor..."
  systemctl --user start artifactflow-pdf-processor-socket-init
  systemctl --user restart artifactflow-pdf-processor
  wait_healthy artifactflow-pdf-processor || die "The enabled PDF processor did not become healthy."
fi
if [ "$XLSX_ENABLED" = "1" ]; then
  echo "== Starting the XLSX processor..."
  systemctl --user start artifactflow-xlsx-processor-socket-init
  systemctl --user restart artifactflow-xlsx-processor
  wait_healthy artifactflow-xlsx-processor || die "The enabled XLSX processor did not become healthy."
fi
if [ "$DOCX_ENABLED" = "1" ]; then
  echo "== Starting the DOCX processor..."
  systemctl --user start artifactflow-docx-processor-socket-init
  systemctl --user restart artifactflow-docx-processor
  wait_healthy artifactflow-docx-processor || die "The enabled DOCX processor did not become healthy."
fi
systemctl --user restart artifactflow-app
wait_healthy artifactflow-app || die "The app did not come up (see journalctl --user -u artifactflow-app)."

echo "== First database migration..."
podman exec artifactflow-app sh -c 'cd /var/www/html && php artisan migrate --force'

# ---------- 6) restricted artifact-host role + grants ----------
echo "== Creating the restricted artifact-host database role..."
ARTHOST_DB_PW="$(read_env DB_PASSWORD "$CFG/artifact-host.env")"
ARTHOST_DB_USER="$(read_env DB_USERNAME "$CFG/artifact-host.env")"
podman exec -i artifactflow-postgres psql -v ON_ERROR_STOP=1 -U artifactflow_app -d artifactflow <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${ARTHOST_DB_USER}') THEN
    CREATE ROLE ${ARTHOST_DB_USER} LOGIN PASSWORD '${ARTHOST_DB_PW}';
  END IF;
END
\$\$;
GRANT CONNECT ON DATABASE artifactflow TO ${ARTHOST_DB_USER};
SQL

echo "== Applying the grants manifest (from release $TAG)..."
GRANTS_URL="https://raw.githubusercontent.com/Gadsotek/artifactflow/$TAG/docs/operations/artifact-host-database-grants.sql"
if have curl && curl -fsSL "$GRANTS_URL" \
     | podman exec -i artifactflow-postgres psql -v ON_ERROR_STOP=1 -U artifactflow_app -d artifactflow -f -; then
  echo "  grants applied."
else
  echo "  !! Could not apply the grants automatically. Apply them manually:"
  echo "     curl -fsSL $GRANTS_URL | podman exec -i artifactflow-postgres psql -U artifactflow_app -d artifactflow -f -"
fi

# ---------- 7) artifact-host + background roles ----------
echo "== Starting artifact-host, worker, and scheduler..."
systemctl --user restart artifactflow-artifact-host artifactflow-worker artifactflow-scheduler
wait_healthy artifactflow-artifact-host || die "The artifact host did not become healthy."

# ---------- 8) first administrator ----------
if [ "$CREATE_ADMIN" = "1" ]; then
  echo
  echo "== First administrator (press Enter at name/email to skip this step)."
  prompt ADMIN_NAME "Administrator name" ""
  if [ -n "$ADMIN_NAME" ]; then
    prompt ADMIN_EMAIL "Administrator email" ""
    prompt_secret ADMIN_PW "Administrator password (min. 12 chars)"
    if printf '%s' "$ADMIN_PW" | podman exec -i \
         -e AF_NAME="$ADMIN_NAME" -e AF_EMAIL="$ADMIN_EMAIL" \
         artifactflow-app sh -c '
           umask 077
           cat > /tmp/af_admin_password
           cd /var/www/html
           ARTIFACTFLOW_ADMIN_PASSWORD_FILE=/tmp/af_admin_password \
             php artisan artifactflow:install --env=production --name="$AF_NAME" --email="$AF_EMAIL"
           rc=$?
           rm -f /tmp/af_admin_password
           exit $rc'; then
      echo "  administrator created."
    else
      echo "  !! Creating the administrator failed (it may already exist). You can do it later:"
      echo "     podman exec -it artifactflow-app sh   # then run artifactflow:install"
    fi
  fi
fi

# ---------- 9) doctor + migrate-on-boot ----------
echo
echo "== Configuration check (artifactflow:doctor). The TRUSTED_PROXIES=REMOTE_ADDR warning is expected."
podman exec artifactflow-app sh -c 'cd /var/www/html && php artisan artifactflow:doctor' || \
  die "artifactflow:doctor reported a failed production requirement."

echo "== Enabling migrate-on-boot (RUN_MIGRATIONS=1) and restarting the app..."
set_env RUN_MIGRATIONS "1" "$CFG/app.env"
systemctl --user restart artifactflow-app
wait_healthy artifactflow-app || die "The app did not become healthy after enabling migrate-on-boot."

# ---------- done ----------
SERVER_IP="$(curl -fsS https://api.ipify.org 2>/dev/null || echo '<your server IP>')"
cat <<INSTALL_DONE

============================================================
 DONE on the server side. Two things remain "from outside":
============================================================

1) DNS: point both hostnames at this server (A records):
     $APP_HOST   ->  $SERVER_IP
     $ART_HOST   ->  $SERVER_IP

2) nginx + HTTPS (run as ROOT):
     # copy the vhosts and replace the placeholder hostnames inside them:
     #   $APP_HOST  and  $ART_HOST
     cp nginx/artifactflow-app.conf       /etc/nginx/sites-available/
     cp nginx/artifactflow-artifacts.conf /etc/nginx/sites-available/
     ln -s /etc/nginx/sites-available/artifactflow-app.conf       /etc/nginx/sites-enabled/
     ln -s /etc/nginx/sites-available/artifactflow-artifacts.conf /etc/nginx/sites-enabled/
     nginx -t && systemctl reload nginx
     certbot --nginx -d $APP_HOST
     certbot --nginx -d $ART_HOST

Once DNS and certificates are in place, open https://$APP_HOST , sign in,
enroll 2FA, and try uploading one artifact.

Service status:  systemctl --user status 'artifactflow-*'
Logs:            journalctl --user -u artifactflow-app
============================================================
INSTALL_DONE

if [ "$PDF_ENABLED" = "1" ] || [ "$XLSX_ENABLED" = "1" ] || [ "$DOCX_ENABLED" = "1" ]; then
  cat <<'PROCESSORDONE'

One or more document formats are enabled. Before relying on them in production,
complete each applicable gate in TESTING.md: verify immutable image provenance,
Network=none, socket-only transport, resource ceilings, distinct credentials,
signed live doctor checks, hostile-file/browser coverage, released Safari/iOS,
and the final evidence-first security review. DOCX additionally requires both
its LibreOffice check and the downstream PDFBox check to remain green.
PROCESSORDONE
fi
