#!/usr/bin/env bash
set -euo pipefail

# ArtifactFlow · guided installer for a single server (rootless Podman).
#
# Run as the `artifactflow` user from a clone of this repository:
#   ./install.sh
#
# The script asks for your two hostnames and mail transport, generates all
# secrets, builds the local images, starts the services in the correct order,
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
#   --enable-pdf    enable PDF on an existing installation WITHOUT touching other
#                   secrets (generates only the PDF secret, wires the processor)
#   --no-admin      skip creating the first administrator

RECONFIGURE=0
CREATE_ADMIN=1
ENABLE_PDF=0
for arg in "$@"; do
  case "$arg" in
    --reconfigure) RECONFIGURE=1 ;;
    --enable-pdf) ENABLE_PDF=1 ;;
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
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
have podman  || die "podman not found (Podman 5.0+). Install it as root: apt install podman"
have openssl || die "openssl not found."
[ -d "$CFG" ] || die "Directory $CFG does not exist. Create it as root (see GUIDE.html, step 0)."
[ -w "$CFG" ] || die "Cannot write to $CFG. Make sure it is owned by the artifactflow user."
have curl || echo "Note: curl not found. You will have to apply the database grants manually (shown at the end)."

TAG="$(sed -n 's/^# Pinned release: ArtifactFlow \(v[0-9.]*\)$/\1/p' quadlet/artifactflow-release.image)"
DIGEST="$(sed -n 's|^Image=ghcr.io/gadsotek/artifactflow@sha256:\([0-9a-f]*\)$|\1|p' quadlet/artifactflow-release.image)"
[ -n "$TAG" ] && [ -n "$DIGEST" ] || die "Could not read version/digest from quadlet/artifactflow-release.image."
echo "Version: $TAG"

# ---------- 1) configuration ----------
PDF_ENABLED=0
if [ -f "$CFG/app.env" ] && [ "$RECONFIGURE" = "0" ]; then
  echo
  echo "== Configuration already exists in $CFG, keeping it (and all secrets)."
  echo "   To enable PDF: ./install.sh --enable-pdf"
  CREATE_ADMIN=0
  APP_HOST="$(read_env APP_URL "$CFG/app.env" | sed 's#^https\?://##')"
  ART_HOST="$(read_env ARTIFACT_URL "$CFG/app.env" | sed 's#^https\?://##')"
  [ "$(read_env PDF_PROCESSOR_ENABLED "$CFG/app.env")" = "true" ] && PDF_ENABLED=1
  if [ "$ENABLE_PDF" = "1" ] && [ "$PDF_ENABLED" = "0" ]; then
    echo "== Enabling PDF on the existing installation (other secrets untouched)."
    echo "   After this, complete the PDF enablement gate in TESTING.md."
    PDF_SECRET="$(gen_secret)"
    set_env PDF_PROCESSOR_ENABLED "true" "$CFG/app.env"
    set_env PDF_PROCESSOR_URL "http://localhost" "$CFG/app.env"
    set_env PDF_PROCESSOR_SOCKET_PATH "/run/artifactflow/pdf-processor/processor.sock" "$CFG/app.env"
    set_env PDF_PROCESSOR_SHARED_SECRET "$PDF_SECRET" "$CFG/app.env"
    set_env PDF_PROCESSOR_SHARED_SECRET "$PDF_SECRET" "$CFG/pdf-processor.env"
    PDF_ENABLED=1
  fi
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
  install -m 0600 env/pdf-processor.env.example "$CFG/pdf-processor.env"

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

  # PDF artifacts (optional, off by default). Production-capable, but enabling it
  # is a per-deployment decision that needs verification after install.
  echo
  echo "PDF artifacts are production-capable but OFF by default. If you enable"
  echo "them, you must still complete the PDF enablement gate in TESTING.md"
  echo "(startup denial proof, doctor, released Safari/iOS check, final review)"
  echo "before relying on PDF in production."
  prompt PDF_KIND "Enable PDF artifacts now? (y/N)" "N"
  case "$PDF_KIND" in
    [Yy]*)
      PDF_ENABLED=1
      PDF_SECRET="$(gen_secret)"
      set_env PDF_PROCESSOR_ENABLED "true" "$CFG/app.env"
      set_env PDF_PROCESSOR_URL "http://localhost" "$CFG/app.env"
      set_env PDF_PROCESSOR_SOCKET_PATH "/run/artifactflow/pdf-processor/processor.sock" "$CFG/app.env"
      set_env PDF_PROCESSOR_SHARED_SECRET "$PDF_SECRET" "$CFG/app.env"
      set_env PDF_PROCESSOR_SHARED_SECRET "$PDF_SECRET" "$CFG/pdf-processor.env"
      echo "  PDF enabled. The processor image will be built and started."
      ;;
    *)
      echo "  PDF left off. Enable it later without touching other secrets:"
      echo "    ./install.sh --enable-pdf"
      ;;
  esac

  echo
  echo "== Secrets generated and written to $CFG (mode 0600)."
  echo "   IMPORTANT: copy APP_KEY and ARTIFACT_URL_SIGNING_KEY from $CFG/app.env"
  echo "   into a password manager. They are in no backup, and losing APP_KEY makes"
  echo "   encrypted data and 2FA unrecoverable."
fi

[ -n "$APP_HOST" ] && [ -n "$ART_HOST" ] || die "Could not determine the hostnames."

# ---------- 2) local images ----------
echo
echo "== Building the database image and the image parser (this takes a while)..."
podman build -f Dockerfile.postgres     -t localhost/artifactflow-postgres:17 .
podman build -f Dockerfile.image-parser -t localhost/artifactflow-image-parser:pinned .

if [ "$PDF_ENABLED" = "1" ]; then
  echo "== Building the PDF processor (opt-in)..."
  ./build-pdf-processor.sh
fi

echo "== Pulling the application image $TAG from GHCR..."
if have gh; then
  echo "   Verifying build provenance (attestation)..."
  gh attestation verify \
    "oci://ghcr.io/gadsotek/artifactflow@sha256:$DIGEST" \
    --repo Gadsotek/artifactflow \
    --signer-workflow Gadsotek/artifactflow/.github/workflows/release.yml \
    --predicate-type https://slsa.dev/provenance/v1 \
    || die "Attestation verification failed for the pinned digest. Do not deploy it."
else
  echo "   !! GitHub CLI (gh) not found: skipping attestation verification here."
  echo "      Verify the pinned digest's provenance elsewhere (see README, Prerequisites)."
fi
podman pull "ghcr.io/gadsotek/artifactflow@sha256:$DIGEST" || \
  echo "  (the pull will be retried when the service starts)"

# ---------- 3) quadlet units ----------
echo "== Installing quadlet units..."
mkdir -p "$HOME/.config/containers/systemd"
# Copy every unit except the PDF-specific ones and the unused pdf network;
# the PDF units are installed only when PDF is enabled.
for f in quadlet/*; do
  case "$(basename "$f")" in
    artifactflow-pdf-processor.container|artifactflow-pdf-processor-socket-init.container|artifactflow-pdf.network)
      continue ;;
  esac
  cp "$f" "$HOME/.config/containers/systemd/"
done
if [ "$PDF_ENABLED" = "1" ]; then
  cp quadlet/artifactflow-pdf-processor.container \
     quadlet/artifactflow-pdf-processor-socket-init.container \
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
systemctl --user start artifactflow-image-parser
if [ "$PDF_ENABLED" = "1" ]; then
  echo "== Starting the PDF processor..."
  systemctl --user start artifactflow-pdf-processor-socket-init
  systemctl --user start artifactflow-pdf-processor
  wait_healthy artifactflow-pdf-processor || \
    echo "  (PDF processor still coming up, check journalctl --user -u artifactflow-pdf-processor)"
fi
systemctl --user start artifactflow-app
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
systemctl --user start artifactflow-artifact-host artifactflow-worker artifactflow-scheduler
wait_healthy artifactflow-artifact-host || echo "  (artifact-host still coming up, check again later)"

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
podman exec artifactflow-app sh -c 'cd /var/www/html && php artisan artifactflow:doctor' || true

echo "== Enabling migrate-on-boot (RUN_MIGRATIONS=1) and restarting the app..."
set_env RUN_MIGRATIONS "1" "$CFG/app.env"
systemctl --user restart artifactflow-app
wait_healthy artifactflow-app || true

# ---------- done ----------
SERVER_IP="$(curl -fsS https://api.ipify.org 2>/dev/null || echo '<your server IP>')"
cat <<DONE

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
DONE

if [ "$PDF_ENABLED" = "1" ]; then
  cat <<'PDFDONE'

PDF is enabled. Before relying on it in production, complete the PDF enablement
gate in TESTING.md: confirm Network=none and hard limits, check the processor's
startup denial log and healthcheck, run artifactflow:doctor, upload a test PDF,
do the released Safari/iOS check, and record the final review.
PDFDONE
fi
