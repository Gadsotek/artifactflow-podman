# First-run test checklist

These scripts were written and reviewed but must be validated end-to-end on a
real VM before this kit is relied on in production. Run this once on a throwaway
server, top to bottom. Use non-sensitive test content only.

## Environment

- [ ] Fresh native amd64 Linux VM, systemd, cgroups v2, Podman >= 5.0,
      nginx, certbot installed.
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
- [ ] Application attestation verification runs (with `gh` present) and passes;
      every enabled processor attestation is independently verified.
- [ ] Postgres becomes healthy; `db-ca.pem` is extracted.
- [ ] App becomes healthy; first migration runs.
- [ ] Restricted `artifactflow_artifact_host` role is created and grants apply
      without error.
- [ ] artifact-host, worker, scheduler start; artifact-host becomes healthy.
- [ ] Admin creation succeeds; `artifactflow:doctor` runs (the
      `TRUSTED_PROXIES=REMOTE_ADDR` warning is expected).
- [ ] `RUN_MIGRATIONS=1` is set and the app restarts healthy.
- [ ] Final block prints the correct hostnames and server IP.
- [ ] PDF, XLSX, and DOCX prompts default to no; `--enable-pdf`,
      `--enable-xlsx`, and `--enable-docx` preserve unrelated secrets.
- [ ] Enabling DOCX also enables PDF. Enabling a format absent from
      `processor-images.lock` fails before changing its feature flag.

## Idempotency

- [ ] Re-running `./install.sh` keeps existing secrets (does not regenerate).
- [ ] `./install.sh --reconfigure` regenerates config as expected.
- [ ] Re-running each `--enable-*` flag does not rotate an existing processor
      secret.
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

## Document processor gate (for every enabled format)

PDF, XLSX, and DOCX are production-capable but off by default. A format with an
empty entry in `processor-images.lock` is unavailable for that application
release and must fail closed on explicit enablement. For every enabled format:

- [ ] Its exact `ghcr.io/...@sha256:...` reference matches the pinned release;
      the release-workflow provenance and CycloneDX SBOM have been verified.
- [ ] `podman inspect artifactflow-<format>-processor` proves `Network=none`,
      read-only rootfs, all capabilities dropped, no-new-privileges, one
      instance, and only its dedicated socket volume.
- [ ] Resource ceilings match the Quadlet: PDF 512 MiB / 1 CPU / 32 PIDs /
      32 MiB tmpfs; XLSX 384 MiB / 1 CPU / 32 PIDs / 64 MiB tmpfs; DOCX
      768 MiB / 1 CPU / 128 PIDs / 192 MiB tmpfs / `nofile=256:256`.
- [ ] Its secret exists only on app + matching processor, differs from every
      other secret, and is empty on artifact-host/worker/scheduler. The latter
      two roles pin every processor feature false.
- [ ] The signed live `artifactflow:doctor` challenge passes. A failed
      processor healthcheck is a deployment failure, not a warning.

### PDF

- [ ] Build and scan the local socket adapter. Its base digest, source SHA,
      launcher, and healthcheck match this kit's release pins. The published
      base uses TCP and cannot itself satisfy the Unix-socket unit.
- [ ] Run natively on amd64 Linux: emulator failures of the process-creation
      seccomp self-test are failures, never a reason to disable the filter.

- [ ] The startup/health evidence required by the release proves the PDFBox
      process-containment filter and socket service are active.
- [ ] Upload a hostile corpus sample (rejected) followed by an accepted native-
      text PDF. The accepted original renders only from the artifact origin.

### XLSX

- [ ] The health result reports the pinned SheetJS profile only after the cold
      worker and loopback-only interface checks pass.
- [ ] Active/malformed workbooks are rejected and a subsequent accepted
      workbook succeeds. Preview/search/share consume only the typed manifest;
      exact-original download remains authenticated.
- [ ] Workbook preview and safe-link behavior pass on Chromium, Firefox, and
      WebKit, including dark theme and a maximum-size representative workbook.

### DOCX (also complete every PDF item)

- [ ] DOCX and PDF secrets differ. The DOCX container receives no PDF secret;
      the app performs the downstream PDFBox validation.
- [ ] LibreOffice startup, network denial, process-group timeout cleanup, and
      the real DOCX-to-searchable-PDF-to-PDFBox chain pass.
- [ ] Active/embedded documents are rejected and a subsequent accepted DOCX
      succeeds. Preview/share expose only the validated PDF derivative; exact
      original download remains authenticated.

- [ ] Released Safari/iOS checks pass for PDF and DOCX-derived PDF presentation.
- [ ] Final evidence-first security review for every enabled format is recorded.

## Upgrade path

- [ ] Bump the digest in `quadlet/artifactflow-release.image` (or merge a
      `release-watch` PR), run `./deploy.sh`, confirm both HTTP surfaces return
      to healthy.

## Backups

- [ ] `pg_dump` and `podman volume export artifactflow-storage` succeed.
- [ ] A restore into a scratch instance boots and serves a known artifact.

Record the OS, Podman version, release tag, and any deviation. File anything
that failed before publishing.

## Automated checks

Run `bash tests/processor-install-contract.sh`, `python3 tests/deployment-contract.py`,
`python3 tests/installer-behavior.py` on Linux, and ShellCheck for the shell
scripts. On Linux with Podman, run
`bash tests/quadlet-generate.sh` to verify the generated systemd units, including
one separate group argument per processor. These checks supplement the VM
checklist above; they do not certify a live deployment.

After building the parser and PDF adapter with their installed local tags, run
`python3 tests/processor-runtime.py` on native amd64 Linux. It starts only
uniquely named throwaway containers/volumes and removes those test resources.
It verifies all four health paths and that a read-only socket mount permits
connections only with the matching group. CI runs this using Docker on amd64;
retain the separate rootless Podman/systemd and end-to-end document checks.
