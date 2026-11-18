# First-run test checklist

These scripts were written and reviewed but must be validated end-to-end on a
real VM before this kit is relied on in production. Run this once on a throwaway
server, top to bottom. Use non-sensitive test content only.

## Environment

- [ ] Fresh native amd64 Linux VM, systemd, cgroups v2, Podman >= 5.0 with
      Netavark/Aardvark-DNS (`podman info --format '{{.Host.NetworkBackend}}'`),
      nginx, certbot installed.
- [ ] Two DNS records you control, on **different hostnames** (ideally a
      registrable domain separate from your other apps for the artifact origin),
      pointing at the VM.
- [ ] A reachable SMTP relay or a Resend key.
- [ ] `gh` available where you verify the release image (workstation is fine).

## Root prep (once)

- [ ] `apt install podman nginx python3-certbot-nginx`
- [ ] `useradd -m -s /bin/bash artifactflow && loginctl enable-linger artifactflow`
- [ ] No config-dir root step needed: the installer creates `~/.config/artifactflow`
      (override with `ARTIFACTFLOW_CONFIG_DIR`) as the app user.

## Installer (`./install.sh` as the artifactflow user)

- [ ] Refuses to run as root.
- [ ] Rejects equal app/artifact hostnames.
- [ ] Rejects empty and placeholder hostnames (`example.com`, `localhost`).
- [ ] Prompts once for hostnames and mail, generates secrets, writes
      `~/.config/artifactflow/*.env` as mode `0600`.
- [ ] Application attestation verification runs (with `gh` present) and passes;
      every enabled processor attestation is independently verified.
- [ ] Postgres becomes healthy; `db-ca.pem` is extracted.
- [ ] App becomes healthy; first migration runs.
- [ ] Restricted `artifactflow_artifact_host` role is created and grants apply
      without error.
- [ ] The grants download uses the pinned `ARTIFACTFLOW_COMMIT`; a failed or
      empty download, or rejected SQL, stops installation before artifact-host
      starts and does not print `DONE`.
- [ ] The configured artifact-host role is the pinned manifest's role and can
      run `SELECT 1 FROM public.pages LIMIT 0` with its own password; a failed
      read stops installation before artifact-host starts.
- [ ] artifact-host, ingress relay, worker, scheduler start; artifact-host and
      relay become healthy.
- [ ] Admin creation succeeds; `artifactflow:doctor` runs (the
      `TRUSTED_PROXIES=REMOTE_ADDR` warning is expected).
- [ ] `RUN_MIGRATIONS=1` is set and the app restarts healthy.
- [ ] Final block prints the correct hostnames and server IP.
- [ ] `podman network inspect` reports `artifactflow-artifact` and
      `artifactflow-artifact-ingress` as internal. `podman inspect` shows
      artifact-host on those two networks only, PostgreSQL on
      `artifactflow-artifact` and `artifactflow`, and the credential-free relay
      on `artifactflow-artifact-ingress` and `artifactflow-edge` only. App,
      worker, scheduler, and optional Reverb join `artifactflow` only.
- [ ] A direct host request to `http://127.0.0.1:8081/login` with the configured
      artifact `Host` header returns 404 after the relay starts. The
      installer/deployer must fail if forwarding hangs or returns another
      status.
- [ ] PDF, XLSX, and DOCX prompts default to no; `--enable-pdf`,
      `--enable-xlsx`, and `--enable-docx` preserve unrelated secrets.
- [ ] Enabling DOCX also enables PDF. Enabling a format absent from
      `processor-images.lock` fails before changing its feature flag.
- [ ] A failed application or processor attestation leaves existing processor
      flags and secrets unchanged; no newly selected processor is started.
- [ ] `--enable-reverb` sets `BROADCAST_CONNECTION=reverb`, generates a
      dedicated `REVERB_APP_SECRET`, pins `REVERB_PUBLIC_URL` and
      `REVERB_ALLOWED_ORIGINS` to `APP_URL`, installs `artifactflow-reverb`, and
      the reverb container becomes healthy before doctor.

## Idempotency

- [ ] Re-running `./install.sh` keeps existing secrets (does not regenerate).
- [ ] `./install.sh --reconfigure` regenerates config as expected.
- [ ] Re-running each `--enable-*` flag does not rotate an existing processor
      secret, nor `REVERB_APP_SECRET`.
- [ ] Role creation and grants are safe to re-apply.

## Edge (root)

- [ ] nginx vhosts installed with real hostnames; `nginx -t` passes.
- [ ] `certbot --nginx -d <app>` and `-d <artifact>` obtain certificates.
- [ ] If Reverb is enabled, the `location /app/` block in the app vhost is
      uncommented and `wss` to `/app/<key>` on the **app** origin reaches Reverb;
      the artifact vhost has no such route and receives no realtime egress. In
      Administration, realtime can be turned on and a second browser sees live
      updates without a reload.

## Browser acceptance

- [ ] Sign in at the app hostname; enroll TOTP 2FA.
- [ ] A saved-artifact preview and a draft preview both render from the
      **artifact** hostname.
- [ ] Upload one PNG/JPEG; it normalizes and displays (image parser path).
- [ ] In devtools, artifact-origin responses carry **no** `Set-Cookie` and no
      app session cookie is sent to the artifact host.
- [ ] The app hostname and artifact hostname are different hosts (not just
      ports).

## Artifact-host network boundary

With both HTTP roles healthy on a native Podman VM, obtain the app container's
`artifactflow` network IP from `podman inspect artifactflow-app`. From the app
or worker container, a connection to `<app-IP>:8080` must succeed. From
`artifactflow-artifact-host`, a connection to that same IP and port must fail.
Also probe both internal networks' bridge gateways, the relay's internal
address, and the public app hostname through host nginx, sending the app
`Host` header: no path may proxy to the app. A direct outbound public IP
connection from artifact-host must fail, not merely a public DNS lookup.
Confirm `/proc/sys/net/ipv4/ip_forward` is `0` inside both artifact-host and
relay and that neither forwards packets between its interfaces.
`artifactflow-postgres` must still resolve, and a saved artifact
preview loads through the artifact hostname. Check outbound mail from the
worker. Record the effective network and routing evidence.

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

- [ ] Upgrade an existing v0.3.0 installation to v0.3.1; both origins return
      healthy, existing data and document opt-ins remain intact, and no new
      migration or environment setting is needed.
- [ ] An HTML artifact with a style element inside a select fails closed with
      the preview-unavailable response; a normal saved artifact still renders.
      Stored source remains accessible to its authorized editor.
- [ ] Upgrade an existing v0.2.1 installation to v0.3.1 with
      `RUN_MIGRATIONS=1` on the app. Both v0.3.0 migrations complete before it
      serves traffic: `personal_page_states` exists and the MCP lifetime
      settings default to 365/90 days. Existing pages, versions, and token
      expirations remain intact.
- [ ] The redesigned Home, favorites, recently opened pages, and Cmd/Ctrl+K
      navigation work after the upgrade; a saved artifact preview remains on
      the isolated origin.
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
