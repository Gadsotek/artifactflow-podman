# artifactflow-podman

Deployment-specific orchestration for running
[ArtifactFlow](https://github.com/Gadsotek/artifactflow) on a **single
virtual server** with **nginx** as the TLS edge and **Podman** (rootless,
systemd Quadlet) as the container runtime.

ArtifactFlow ships an attested production image and a runtime contract
(`docs/OPERATIONS.md` in the main repository) and deliberately no deployment
automation, operators provide orchestration. This repository is that
orchestration for one VM. Read the main repository's OPERATIONS document
first; this runbook covers only what this topology looks like and the exact
provisioning steps.

**Pinned release: v0.2.1** (digest in `quadlet/artifactflow-release.image`).
The application is never built here: every app-role unit runs the release
image from GHCR by digest. The image parser is built from the pinned release's
source (`Dockerfile.image-parser`). XLSX and DOCX use the published immutable
images in `processor-images.lock`. PDF uses a small local socket adapter over
the published PDF image, adding the same source revision's socket launcher and
healthcheck (`Dockerfile.pdf-processor`). The upstream attestation covers the
adapter's base, not the resulting locally built image.

> **Availability is lock-driven:** an empty processor value means the pinned
> application release did not publish that format. The installer omits its
> prompt and an explicit enable flag fails closed until a release bump supplies
> the immutable digest.

## Scope and status

- **What this is:** a reference deployment for **one server**: rootless Podman
  with systemd Quadlet, nginx terminating TLS, self-managed PostgreSQL. It is
  the reference topology from the main repository's `docs/OPERATIONS.md`.
- **What this is not:** a universal deployer. No multi-node, no Kubernetes, no
  Docker Swarm, no managed PaaS. One replica per role by design.
- **Status:** the Quadlet units and env contract follow the pinned release's
  runtime contract, and the scripts are reviewed, but they have **not yet been
  run end-to-end on a live VM**. Do that once first: see `TESTING.md`.
- **New here?** `GUIDE.html` is the short, friendly walkthrough; this README is
  the full reference. Security model and reporting: `SECURITY.md`. License: MIT
  (`LICENSE`).
- **Supported host:** native **amd64 Linux**, systemd, cgroups v2, and Podman
  >= 5.0. The published v0.2.1 images are amd64; ARM hosts and x86 emulation
  cannot establish the native processor containment contract. The commands
  below use Debian/Ubuntu package names.

## Shape

This kit applies the release's runtime contract to one VM:

- **nginx terminates TLS only.** Each container runs its own Caddy/FrankenPHP
  web server; nginx proxies two hostnames to two loopback ports and sets the
  `X-Forwarded-*` headers. It must add nothing on the artifact vhost
  (see the hard rule in `nginx/artifactflow-artifacts.conf`).
- **Two origins, one machine.** The origin boundary is a browser concept
  keyed on hostname: `app` and `artifact-host` run as separate containers
  behind separate DNS names. The app hostname and artifact hostname must
  differ by **host**, not port, cookies ignore ports.
- **Shared artifact storage, asymmetric mounts.** One named volume
  (`artifactflow-storage`) is mounted read/write in `app` and **read-only**
  in `artifact-host`, per the documented preference. A one-shot init unit
  pre-creates the directory tree so the read-only mount never races first
  boot.
- **Self-managed Postgres TLS.** The boot gate requires
  `DB_SSLMODE=verify-full`; `Dockerfile.postgres` keeps a deployment-private
  CA on the data volume and issues a server certificate for the container's
  DNS name each boot. The CA certificate is extracted once to
  `/etc/artifactflow/db-ca.pem` and bind-mounted read-only into every
  app-image container, a VM has file mounts, so no `DB_CA_PEM` indirection
  is needed.
- **Restricted artifact-host database role.** The artifact-host unit overrides
  `DB_USERNAME`/`DB_PASSWORD` via `/etc/artifactflow/artifact-host.env` with a
  standalone role granted only what the reviewed manifest
  (`docs/operations/artifact-host-database-grants.sql` at the pinned release
  tag) allows: page/version/share reads, `UPDATE (updated_at)` for its lock
  paths, and the separate artifact rate-limit tables.
- **Isolated image parser.** The app reaches it through a private Unix socket
  with `Network=none`. Each parser has its own socket volume. The app joins
  socket GIDs 10001–10004 through separate Quadlet `GroupAdd=` entries;
  other roles receive no socket mount or connection credential. Sockets use
  mode `0660`.
- **One coherent release lock.** `quadlet/artifactflow-release.image` pins the
  application and `processor-images.lock` pins each independently published
  document processor from the same tag. The installer rejects a mismatched
  tag, missing required processor, or non-digest image reference.

## Service map

| Unit | Role | Image | Port (loopback) | Volumes |
| --- | --- | --- | --- | --- |
| `artifactflow-app` | `app` | release digest | `127.0.0.1:8080` | storage rw, db-ca + processor sockets ro |
| `artifactflow-artifact-host` | `artifact-host` | release digest | `127.0.0.1:8081` | storage **ro**, db-ca ro |
| `artifactflow-worker` | `worker` | release digest | none | db-ca ro |
| `artifactflow-scheduler` | `scheduler` | release digest | none | db-ca ro |
| `artifactflow-storage-init` | one-shot init | release digest | none | storage rw |
| `artifactflow-postgres` | database | local build | none (network-internal) | `artifactflow-db` |
| `artifactflow-image-parser` | image parser | local build | none (`Network=none`) | image-socket rw |
| `artifactflow-pdf-processor` | PDF processor (opt-in) | local socket adapter | none (`Network=none`) | pdf-socket rw |
| `artifactflow-xlsx-processor` | XLSX processor (opt-in) | release digest | none (`Network=none`) | xlsx-socket rw |
| `artifactflow-docx-processor` | DOCX processor (opt-in; requires PDF) | release digest | none (`Network=none`) | docx-socket rw |
| `artifactflow-*-processor-socket-init` | one-shot socket owners (opt-in) | matching processor | none | matching socket rw |

Each document processor and its initializer is installed only when enabled.
The image parser and its initializer are always installed. Application roles
and PostgreSQL join `artifactflow`; all parsers use `Network=none`. The old
`artifactflow-parser` network definition is retained for older installations,
but no current container joins it.

## Prerequisites

1. A native **amd64 Linux VM** with cgroups v2 and **Podman ≥ 5.0** (Quadlet
   `.image` units, pasta networking),
   nginx, and certbot (`python3-certbot-nginx`). Any systemd distribution
   works; package names below are Debian/Ubuntu.
2. Two DNS records pointing at the VM: the app hostname (e.g.
   `flow.example.com`) and the artifact hostname (e.g.
   `artifacts.example.com`). Different hostnames are a security requirement,
   not a convention; a subdomain of the same zone is fine.
3. An SMTP relay (or Resend account) the installation may send through. The
   boot gate refuses `MAIL_MAILER=log` in production; a deliverable transport
   is a first-boot requirement (invitations and password resets are mail).
4. The GitHub CLI wherever you verify releases (can be your workstation).
   Verify the application and every enabled processor before first use and
   after every digest bump:

   ```sh
   gh attestation verify \
     oci://ghcr.io/gadsotek/artifactflow@sha256:<digest from quadlet/artifactflow-release.image> \
     --repo Gadsotek/artifactflow \
     --signer-workflow Gadsotek/artifactflow/.github/workflows/release.yml \
     --predicate-type https://slsa.dev/provenance/v1
   ```

   Processor references come from `processor-images.lock`; use the same command
   with its complete `ghcr.io/...@sha256:...` value. The installer verifies
   them automatically when `gh` is present.

   The signer-workflow pin matters: `--repo` alone accepts an attestation
   from any workflow in the repository, not just the release pipeline.
5. Secrets generated out of band (never commit them, never reuse one for
   another slot), commands in `env/app.env.example`.

## Install

As root:

```sh
apt install podman nginx python3-certbot-nginx
useradd -m -s /bin/bash artifactflow
loginctl enable-linger artifactflow          # user services survive logout & start at boot
mkdir -p /etc/artifactflow
chown artifactflow:artifactflow /etc/artifactflow
chmod 0700 /etc/artifactflow
```

As `artifactflow` (note: over ssh, `systemctl --user` needs
`export XDG_RUNTIME_DIR=/run/user/$(id -u)` in some setups), from a clone of
this repository, the recommended path is:

```sh
./install.sh
```

The guided installer offers every processor published by the pinned release.
All default to off; use `--enable-pdf`, `--enable-xlsx`, or `--enable-docx` for
an explicit non-interactive format selection (DOCX includes PDF). It preserves
existing secrets unless `--reconfigure` is supplied.

To enable all three document formats on a new or existing installation:

```sh
./install.sh --enable-xlsx --enable-docx
```

DOCX includes PDF. The installer refreshes processor containers and both HTTP
origins before its live doctor check. Existing keys are preserved. Never use
`--reconfigure` on a populated installation: it rotates encryption keys and
database credentials.

The manual configuration equivalent starts with:

> The manual path below leaves all document processors disabled. Use the guided
> installer to enable one; it validates the release lock, generates the correct
> isolated secret pair, prepares the pinned image, and installs only its units.

```sh
# Configuration
install -m 0600 env/app.env.example           /etc/artifactflow/app.env
install -m 0600 env/postgres.env.example      /etc/artifactflow/postgres.env
install -m 0600 env/parser.env.example        /etc/artifactflow/parser.env
install -m 0600 env/artifact-host.env.example /etc/artifactflow/artifact-host.env
# ...fill in app.env, postgres.env, parser.env, and artifact-host.env
# (secrets, hostnames, SMTP). The image-parser secret is one value in two
# places: IMAGE_PARSER_SHARED_SECRET in app.env and in parser.env.
# The guided installer creates a processor env file only when its format is
# explicitly enabled.

# Local database image
podman build -f Dockerfile.postgres -t localhost/artifactflow-postgres:17 .

# Image parser, built from the pinned release source
podman build -f Dockerfile.image-parser -t localhost/artifactflow-image-parser:pinned .

# Quadlet units. The guided installer copies only explicitly enabled processor
# units; do the same for a manual installation.
mkdir -p ~/.config/containers/systemd
cp quadlet/artifactflow-{app,artifact-host,image-parser,image-parser-socket-init,postgres,scheduler,storage-init,worker}.container \
   quadlet/artifactflow.network \
   quadlet/artifactflow-release.image \
   ~/.config/containers/systemd/
systemctl --user daemon-reload
```

## First boot

1. **Database first**, its CA must exist before any app unit can mount it:

   ```sh
   systemctl --user start artifactflow-postgres
   podman exec artifactflow-postgres \
     cat /var/lib/postgresql/data/certs/root.crt > /etc/artifactflow/db-ca.pem
   chmod 0644 /etc/artifactflow/db-ca.pem
   ```

2. **App surface and parser** (`RUN_MIGRATIONS=0` at this point, the boot
   gate is configuration-only, so the app boots against an empty schema):

   ```sh
   systemctl --user start artifactflow-image-parser artifactflow-app
   ```

   If a unit restart-loops, `journalctl --user -u artifactflow-app` names the
   failing boot-gate check.

3. **First migration**, must be non-`--isolated` (the isolation lock lives
   in the not-yet-created cache table):

   ```sh
   podman exec artifactflow-app php artisan migrate --force
   ```

4. **Restricted artifact-host database role**, the migration just created
   the tables the grant manifest references. Create the role with the
   password from `/etc/artifactflow/artifact-host.env`, then apply the
   reviewed manifest from the pinned release tag:

   ```sh
   podman exec -it artifactflow-postgres psql -U artifactflow_app -d artifactflow \
     -c "CREATE ROLE artifactflow_artifact_host LOGIN PASSWORD '<password from artifact-host.env>'" \
     -c "GRANT CONNECT ON DATABASE artifactflow TO artifactflow_artifact_host"
   curl -fsSL https://raw.githubusercontent.com/Gadsotek/artifactflow/v0.2.1/docs/operations/artifact-host-database-grants.sql \
     | podman exec -i artifactflow-postgres psql -U artifactflow_app -d artifactflow -f -
   ```

5. **Artifact surface** (started only after the grants exist):

   ```sh
   systemctl --user start artifactflow-artifact-host
   ```

6. **Workers** (started only now, so they never crash-loop on the missing
   schema):

   ```sh
   systemctl --user start artifactflow-worker artifactflow-scheduler
   ```

7. **First System Admin** (interactive, inside the container):

   ```sh
   podman exec -it artifactflow-app sh
   # inside:
   umask 077
   printf '%s' '<admin password, 12+ chars>' > /tmp/af_admin_password
   ARTIFACTFLOW_ADMIN_PASSWORD_FILE=/tmp/af_admin_password \
     php artisan artifactflow:install --env=production --name='<name>' --email='<email>'
   rm -f /tmp/af_admin_password
   php artisan artifactflow:doctor
   exit
   ```

   `doctor` warns about `TRUSTED_PROXIES=REMOTE_ADDR`; that is expected here
  , the container ports are loopback-bound and reachable only through nginx.

8. Set `RUN_MIGRATIONS=1` in `/etc/artifactflow/app.env` and
   `systemctl --user restart artifactflow-app`, so future deploys migrate on
   boot (the `--isolated` lock works from now on and guards overlapping
   restarts). The artifact-host unit pins `RUN_MIGRATIONS=0` regardless.

9. **Edge** (as root): copy the two vhosts from `nginx/`, replace the
   placeholder hostnames, then:

   ```sh
   ln -s /etc/nginx/sites-available/artifactflow-app.conf /etc/nginx/sites-enabled/
   ln -s /etc/nginx/sites-available/artifactflow-artifacts.conf /etc/nginx/sites-enabled/
   nginx -t && systemctl reload nginx
   certbot --nginx -d flow.example.com
   certbot --nginx -d artifacts.example.com
   ```

10. Sign in at the app hostname, enroll TOTP 2FA (required for System
    Admins), walk one saved-artifact preview and one draft preview to
    confirm the artifact origin end to end, and upload one real PNG or JPEG
    to confirm the parser path.

## Upgrades

**Upgrading from this kit's v0.1.0 pin:** after updating this repository, run
`./install.sh --no-admin` once (add `--enable-xlsx --enable-docx` if desired).
It preserves the existing keys and changes the obsolete image-parser TCP
configuration to the release's required Unix socket. `deploy.sh` refuses the
old transport before restarting services. Do not use `--reconfigure`.

1. Read the release notes; a release that introduces new required
   configuration fails its boot gate on deploy and restart-loops with the
   failing check named in the journal, add the new variables/units first.
2. Verify the application and every published PDF/XLSX/DOCX digest from the
   release (command under Prerequisites).
3. Edit the application digest in `quadlet/artifactflow-release.image`, all
   processor references in `processor-images.lock`, and both pinned-release
   comments. Update `ARTIFACTFLOW_COMMIT` and the PHP base digest in
   `Dockerfile.image-parser` from the new tag.
4. Copy the changed quadlet files to `~/.config/containers/systemd/`, then:

   ```sh
   systemctl --user daemon-reload
   systemctl --user restart artifactflow-image-parser artifactflow-app \
     artifactflow-artifact-host artifactflow-worker artifactflow-scheduler
   ```

   With `RUN_MIGRATIONS=1`, the app migrates on boot under the isolation
   lock. The artifact-host may restart-loop until the app's migration
   finishes; it self-heals through `Restart=always`.
5. If the release notes change
   `docs/operations/artifact-host-database-grants.sql`, re-apply it from the
   new tag (command in First boot step 4) after the migration.

Commit the digest bump here so the repo stays the record of what runs.

Both halves are automated while keeping a human between them:

- `.github/workflows/release-watch.yml` (active once this repo lives on
  GitHub with "Allow GitHub Actions to create and approve pull requests"
  enabled) checks daily for a new release, requires and verifies all four
  image attestations, and opens the coherent digest-bump PR. The PR body
  carries the release link, all image references, plus diffs
  of the artifact-host grants manifest and `.env.production.example` between
  the tags, so new required configuration is visible before merge. A failed
  attestation produces no PR.
- `./deploy.sh`, run on the VM as `artifactflow`, applies the merged state:
  pull, re-verify the application and enabled processor attestations (or
  `--no-verify` only after external verification), rebuild the parser image,
  install Quadlets, restart enabled processors before application roles, and
  wait for all enabled processors and both HTTP surfaces to report healthy.

Deliberately NOT automated: nothing deploys on merge. The VM changes only
when an operator runs `./deploy.sh`, and grants-manifest changes are applied
by hand from the PR diff.

## Operations notes

- **Backups.** Quiesce application writes, uploads, and retention cleanup for
  both exports. Dump the database first, then artifact files, and keep writes
  paused until both finish. A deletion between the dump and storage export
  can otherwise leave the backup missing a referenced blob. Test restoration
  into a separate instance.

  ```sh
  podman exec artifactflow-postgres pg_dump -U artifactflow_app -Fc artifactflow > backup.dump
  podman volume export artifactflow-storage > storage.tar
  ```

  `APP_KEY`, `ARTIFACT_URL_SIGNING_KEY`, `IMAGE_PARSER_SHARED_SECRET`, every
  enabled processor secret, and the DB CA key live only in
  `/etc/artifactflow` and the postgres volume:
  keep an out-of-band copy of the secrets in a password manager; losing
  `APP_KEY` makes TOTP secrets and encrypted data unrecoverable. The
  parser/processor secrets protect no data at rest; rotate each matching pair
  together or that format's writes fail closed until they match.
- **Logs** go to the user journal: `journalctl --user -u artifactflow-app`
  (likewise per unit). `LOG_CHANNEL=stderr` keeps Laravel logs there too.
- **Scaling.** Keep one replica per role. The reference admission design
  assumes coordinated replicas; this repo deliberately models the
  single-VM case.
- **Realtime (Reverb) is intentionally off** (`BROADCAST_CONNECTION=null`).
  Enabling it later means another quadlet unit, the `REVERB_*` variable set
  from the release's `.env.production.example`, and websocket upgrade
  headers in the app vhost.
- **Loopback invariant.** Nothing may ever publish 8080/8081 on a routable
  address, and no firewall rule may forward to them: `TRUSTED_PROXIES=REMOTE_ADDR`
  makes the immediate peer trusted, which is safe only while that peer can
  only be nginx.

## PDF, XLSX, and DOCX uploads (production-capable, default-off)

PDF artifacts are **production-capable and off by default** since v0.1.0. There
are two layers: the release itself is hardened (isolated processor, seccomp
outbound denial, HMAC, hard limits, healthcheck, a separate attested image), and
each deployment must be verified before enabling PDF (private-only reachability,
Unix socket, one replica / concurrency one, resource limits, startup-denial
proof, `artifactflow:doctor`, released Safari/iOS check, final review). See the
release's `RELEASE-CHECKLIST.md` and `docs/OPERATIONS.md` "Production PDF
processor".

Releases that publish XLSX and DOCX add the same explicit opt-in at two distinct
boundaries: XLSX projects an exact private workbook into a bounded typed
manifest, while DOCX converts an exact private original with networkless
LibreOffice and requires the output to pass the independently credentialed PDF
processor before the derivative is accepted. Empty Office image-lock entries
are deliberate and make those formats unavailable for that application pin.

This kit wires each format as an explicit installer opt-in. `install.sh` asks
separately (default no), generates a distinct processor secret, verifies and
pulls the release image by digest, and installs only the selected units. Use
`--enable-pdf`, `--enable-xlsx`, or `--enable-docx` later without rotating
unrelated secrets. DOCX automatically enables its required PDF chain. A format
whose image is absent from the pinned release fails closed before enablement.

The configuration encodes the following restrictions. Verify their effective
behavior on the actual Linux host before production enablement:

- **Transport:** each format has a separate **Unix domain socket over a named
  volume** with `Network=none`, no TCP port, and no external route. The app
  mounts sockets read-only; `*_PROCESSOR_URL=http://localhost` names cURL's
  nominal origin while the socket is the actual transport.
- **One replica, hard limits:** PDF uses 512 MiB / 1 CPU / 32 PIDs / 32 MiB
  tmpfs; XLSX uses 384 MiB / 1 CPU / 32 PIDs / 64 MiB tmpfs; DOCX uses
  768 MiB / 1 CPU / 128 PIDs / 192 MiB tmpfs plus `nofile=256:256`. Every
  processor is non-root, read-only, capability-free, and `no-new-privileges`.
- **Secret and role isolation:** every processor has a unique secret present
  only in app.env and its own processor env. The artifact host inherits only
  presentation flags with empty connection fields; worker and scheduler pin
  every processor flag false and every processor connection field empty.
- **Format boundary:** XLSX returns only the bounded canonical typed manifest.
  DOCX returns a PDF to the app, which must pass the separately credentialed
  PDFBox DOCX-preview profile before the derivative may be stored or served.

What the kit cannot do for you is the **deployment evidence**. Complete every
applicable gate in `TESTING.md`: image/SBOM review, effective network and
resource inspection, signed live doctor challenge, hostile-file and browser
checks, released Safari/iOS, and final evidence-first review. DOCX is not ready
unless both its LibreOffice processor and downstream PDF processor pass.
