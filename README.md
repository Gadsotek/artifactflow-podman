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

**Pinned release: v0.1.0** (digest in `quadlet/artifactflow-release.image`).
The application is never built here, every app-role unit runs the release
image from GHCR by digest. The image parser is the one locally built
app-component: the release publishes no parser image, so it is built from the
pinned release's source (`Dockerfile.image-parser`).

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
- **Supported OS:** any systemd distribution with Podman >= 5.0. The commands
  below use Debian/Ubuntu package names.

## Shape

Unlike the Railway deployment, nothing forces a deviation from the reference
topology, this *is* the reference topology from OPERATIONS.md:

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
- **Isolated image parser.** The app role reaches the parser over an
  `Internal=true` network with no external route; the parser holds only its
  shared secret, and every other role pins that secret empty (their boot gate
  rejects a non-empty value).
- **Single digest pin.** `quadlet/artifactflow-release.image` is the one
  place the release digest lives; all five app-image units reference it.

## Service map

| Unit | Role | Image | Port (loopback) | Volumes |
| --- | --- | --- | --- | --- |
| `artifactflow-app` | `app` | release digest | `127.0.0.1:8080` | storage rw, db-ca ro |
| `artifactflow-artifact-host` | `artifact-host` | release digest | `127.0.0.1:8081` | storage **ro**, db-ca ro |
| `artifactflow-worker` | `worker` | release digest | none | db-ca ro |
| `artifactflow-scheduler` | `scheduler` | release digest | none | db-ca ro |
| `artifactflow-storage-init` | one-shot init | release digest | none | storage rw |
| `artifactflow-postgres` | database | local build | none (network-internal) | `artifactflow-db` |
| `artifactflow-image-parser` | image parser | local build | none (internal network) | none |
| `artifactflow-pdf-processor` | PDF processor (opt-in) | local build | none (`Network=none`) | pdf-socket rw |
| `artifactflow-pdf-processor-socket-init` | one-shot init (opt-in) | local build | none | pdf-socket rw |

The two PDF units and their shared `artifactflow-pdf-socket` volume exist only
when PDF is enabled (installer opt-in). Networks: `artifactflow` (app,
artifact-host, worker, scheduler, postgres; DNS by container name) and
`artifactflow-parser` (`Internal=true`, parser + app only). The PDF processor
uses **no network** (`Network=none`); it is reached only over a Unix socket on
the shared volume.

## Prerequisites

1. A VM with **Podman ≥ 5.0** (Quadlet `.image` units, pasta networking),
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
   Verify the pinned image before first use and after every digest bump:

   ```sh
   gh attestation verify \
     oci://ghcr.io/gadsotek/artifactflow@sha256:<digest from quadlet/artifactflow-release.image> \
     --repo Gadsotek/artifactflow \
     --signer-workflow Gadsotek/artifactflow/.github/workflows/release.yml \
     --predicate-type https://slsa.dev/provenance/v1
   ```

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
this repository:

```sh
# Configuration
install -m 0600 env/app.env.example           /etc/artifactflow/app.env
install -m 0600 env/postgres.env.example      /etc/artifactflow/postgres.env
install -m 0600 env/parser.env.example        /etc/artifactflow/parser.env
install -m 0600 env/artifact-host.env.example /etc/artifactflow/artifact-host.env
install -m 0600 env/pdf-processor.env.example /etc/artifactflow/pdf-processor.env
# ...fill in app.env, postgres.env, parser.env, and artifact-host.env
# (secrets, hostnames, SMTP). The image-parser secret is one value in two
# places: IMAGE_PARSER_SHARED_SECRET in app.env and in parser.env.
# pdf-processor.env stays empty until the PDF release.

# Local database image
podman build -f Dockerfile.postgres -t localhost/artifactflow-postgres:17 .

# Image parser, built from the pinned release source
podman build -f Dockerfile.image-parser -t localhost/artifactflow-image-parser:pinned .

# Quadlet units
mkdir -p ~/.config/containers/systemd
cp quadlet/* ~/.config/containers/systemd/
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
   curl -fsSL https://raw.githubusercontent.com/Gadsotek/artifactflow/v0.1.0/docs/operations/artifact-host-database-grants.sql \
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

1. Read the release notes; a release that introduces new required
   configuration fails its boot gate on deploy and restart-loops with the
   failing check named in the journal, add the new variables/units first.
2. `gh attestation verify` the new digest (command under Prerequisites).
3. Edit the digest in `quadlet/artifactflow-release.image` (and the pinned
   release comment). Update `ARTIFACTFLOW_COMMIT` and the php base digest in
   `Dockerfile.image-parser` from the new tag, and rebuild
   `localhost/artifactflow-image-parser:pinned`.
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
  enabled) checks daily for a new release, verifies its attestation, and
  opens the digest-bump PR. The PR body carries the release link plus diffs
  of the artifact-host grants manifest and `.env.production.example` between
  the tags, so new required configuration is visible before merge. A failed
  attestation produces no PR.
- `./deploy.sh`, run on the VM as `artifactflow`, applies the merged state:
  pull, re-verify the attestation (or `--no-verify` where gh is absent),
  rebuild the parser image, install quadlets, restart all units in order,
  and wait for both HTTP surfaces to report healthy.

Deliberately NOT automated: nothing deploys on merge. The VM changes only
when an operator runs `./deploy.sh`, and grants-manifest changes are applied
by hand from the PR diff.

## Operations notes

- **Backups.** Documented ordering: database dump first, then artifact
  files.

  ```sh
  podman exec artifactflow-postgres pg_dump -U artifactflow_app -Fc artifactflow > backup.dump
  podman volume export artifactflow-storage > storage.tar
  ```

  `APP_KEY`, `ARTIFACT_URL_SIGNING_KEY`, `IMAGE_PARSER_SHARED_SECRET`, and
  the DB CA key live only in `/etc/artifactflow` and the postgres volume:
  keep an out-of-band copy of the secrets in a password manager; losing
  `APP_KEY` makes TOTP secrets and encrypted data unrecoverable. The parser
  secret protects no data at rest; rotate it in app.env and parser.env
  together or image writes fail closed until they match.
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

## PDF uploads (production-capable, default-off, opt-in)

PDF artifacts are **production-capable and off by default** since v0.1.0. There
are two layers: the release itself is hardened (isolated processor, seccomp
outbound denial, HMAC, hard limits, healthcheck, a separate attested image), and
each deployment must be verified before enabling PDF (private-only reachability,
Unix socket, one replica / concurrency one, resource limits, startup-denial
proof, `artifactflow:doctor`, released Safari/iOS check, final review). See the
release's `RELEASE-CHECKLIST.md` and `docs/OPERATIONS.md` "Production PDF
processor".

This kit wires PDF as an **installer opt-in**. `install.sh` asks once (default
no); choosing yes generates a dedicated `PDF_PROCESSOR_SHARED_SECRET`, sets the
app-role values, builds the processor image (`build-pdf-processor.sh`, from the
pinned release source via the release's own Dockerfile), and installs and starts
the processor units. Choosing no leaves `PDF_PROCESSOR_ENABLED=false` and no
processor container. Enable it later with `./install.sh --reconfigure`.

How the container is set up here already satisfies the deployment-side
requirements by construction:

- **Transport:** a **Unix domain socket over a shared volume** with
  `Network=none`, so there is no processor TCP port and no external route. The
  app mounts the socket read-only; `PDF_PROCESSOR_URL` stays `http://localhost`
  and the real transport is the socket. `artifactflow-pdf-processor-socket-init`
  gives the volume to the processor's non-root user first.
- **One replica, hard limits:** a single processor unit, `--memory=512m
  --cpus=1.0`, `PidsLimit=32`, read-only root filesystem, all capabilities
  dropped, `no-new-privileges`, and a 32 MiB noexec/nosuid `/tmp`.
- **Secret isolation:** the processor secret lives only in app.env and
  pdf-processor.env; artifact-host, worker, and scheduler pin it empty, and
  worker/scheduler pin `PDF_PROCESSOR_ENABLED=false`. artifact-host receives the
  enabled flag for presentation only, with empty connection values.

What the kit cannot do for you is the **verification**: after enabling, complete
the "PDF enablement gate" in `TESTING.md` (startup denial-log check, doctor,
released Safari/iOS test, final review) before relying on PDF in production. The
Java/PDFBox processor image is heavier than the PHP image parser and downloads
its dependencies at build time.
