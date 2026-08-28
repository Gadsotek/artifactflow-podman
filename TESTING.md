# First-run test checklist

These scripts were written and reviewed but must be validated end-to-end on a
real VM before this kit is relied on in production. Run this once on a throwaway
server, top to bottom. Use non-sensitive test content only.

## Environment

- [ ] Fresh VM, systemd, Podman >= 5.0, nginx, certbot installed.
- [ ] Two DNS records you control, on **different hostnames** (ideally a
      registrable domain separate from your other apps for the artifact origin),
      pointing at the VM.
- [ ] A reachable SMTP relay or a Resend key.
- [ ] `gh` available where you verify the release image (workstation is fine).

## Root prep (once)

- [ ] `apt install podman nginx python3-certbot-nginx`
- [ ] `useradd -m -s /bin/bash artifactflow && loginctl enable-linger artifactflow`
- [ ] `mkdir -p /etc/artifactflow && chown artifactflow:artifactflow /etc/artifactflow && chmod 0700 /etc/artifactflow`

## Installer (`./install.sh` as the artifactflow user)

- [ ] Refuses to run as root.
- [ ] Rejects equal app/artifact hostnames.
- [ ] Rejects empty and placeholder hostnames (`example.com`, `localhost`).
- [ ] Prompts once for hostnames and mail, generates secrets, writes
      `/etc/artifactflow/*.env` as mode `0600`.
- [ ] Attestation verification runs (with `gh` present) and passes.
- [ ] Postgres becomes healthy; `db-ca.pem` is extracted.
- [ ] App becomes healthy; first migration runs.
- [ ] Restricted `artifactflow_artifact_host` role is created and grants apply
      without error.
- [ ] artifact-host, worker, scheduler start; artifact-host becomes healthy.
- [ ] Admin creation succeeds; `artifactflow:doctor` runs (the
      `TRUSTED_PROXIES=REMOTE_ADDR` warning is expected).
- [ ] `RUN_MIGRATIONS=1` is set and the app restarts healthy.
- [ ] Final block prints the correct hostnames and server IP.

## Idempotency

- [ ] Re-running `./install.sh` keeps existing secrets (does not regenerate).
- [ ] `./install.sh --reconfigure` regenerates config as expected.
- [ ] Role creation and grants are safe to re-apply.

## Edge (root)

- [ ] nginx vhosts installed with real hostnames; `nginx -t` passes.
- [ ] `certbot --nginx -d <app>` and `-d <artifact>` obtain certificates.

## Browser acceptance

- [ ] Sign in at the app hostname; enroll TOTP 2FA.
- [ ] A saved-artifact preview and a draft preview both render from the
      **artifact** hostname.
- [ ] Upload one PNG/JPEG; it normalizes and displays (image parser path).
- [ ] In devtools, artifact-origin responses carry **no** `Set-Cookie` and no
      app session cookie is sent to the artifact host.
- [ ] The app hostname and artifact hostname are different hosts (not just
      ports).

## PDF enablement gate (only if you enabled PDF)

PDF is production-capable but off by default. If you opted in during install,
complete this per-deployment gate before relying on PDF. The container is
already set up to meet the deployment-side requirements; this verifies it.

- [ ] `install.sh` PDF prompt defaulted to no and only enabled on explicit yes.
- [ ] The processor image built from the pinned release source
      (`build-pdf-processor.sh`) and `artifactflow-pdf-processor` is healthy.
- [ ] `podman inspect artifactflow-pdf-processor` shows `Network=none`, memory
      512 MiB, CPUs 1, PidsLimit 32, read-only rootfs, all caps dropped,
      no-new-privileges. One replica only.
- [ ] The processor startup log shows its containment filter active (process
      creation denial), per OPERATIONS; a failed healthcheck is a hard failure.
- [ ] `PDF_PROCESSOR_SHARED_SECRET` is set only on app + processor; artifact-host,
      worker, scheduler have it empty. Worker/scheduler have
      `PDF_PROCESSOR_ENABLED=false`. The secret is not reused from `APP_KEY`, the
      signing key, or the image-parser secret.
- [ ] `artifactflow:doctor` reports no PDF configuration error.
- [ ] Upload a PDF: extraction works, the artifact renders from the artifact
      host, and the original bytes are never served from the app origin.
- [ ] Released Safari/iOS check passes per OPERATIONS.
- [ ] Final evidence-first security review recorded.

## Upgrade path

- [ ] Bump the digest in `quadlet/artifactflow-release.image` (or merge a
      `release-watch` PR), run `./deploy.sh`, confirm both HTTP surfaces return
      to healthy.

## Backups

- [ ] `pg_dump` and `podman volume export artifactflow-storage` succeed.
- [ ] A restore into a scratch instance boots and serves a known artifact.

Record the OS, Podman version, release tag, and any deviation. File anything
that failed before publishing.
