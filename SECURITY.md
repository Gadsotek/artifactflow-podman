# Security

This repository is deployment orchestration for [ArtifactFlow](https://github.com/Gadsotek/artifactflow)
on a single server (rootless Podman, systemd Quadlet, nginx TLS edge). It ships
no application source; every app-role container runs the attested release image
by digest.

## Security model this deployment enforces

- **Two browser origins.** The app and the artifact host run as separate
  containers behind two different hostnames. The artifact origin serves
  untrusted, user-authored HTML/JS; keeping it on a different host (ideally a
  different registrable domain) is what isolates that code from the app's
  cookies, session, and DOM. The installer refuses equal hostnames.
- **Cookie isolation.** `SESSION_DOMAIN` is left unset so the app session
  cookie stays host-only and never reaches the artifact origin. The
  artifact-host Caddy role strips every `Set-Cookie`; the nginx artifact vhost
  is a bare TLS pass-through and must add no cookies or headers.
- **Database TLS.** PostgreSQL runs with a deployment-private CA and
  `DB_SSLMODE=verify-full`; the app verifies the server certificate hostname.
- **Least-privilege artifact-host DB role.** The artifact host connects with a
  separate, standalone PostgreSQL role granted only what the release's reviewed
  manifest allows (page/version/share reads, `UPDATE(updated_at)` for its lock
  paths, the artifact rate-limit tables). It cannot touch app write, auth, or
  limiter state.
- **Isolated image parser.** The parser is reached over an `Internal=true`
  network with no external route and holds only its shared secret; every other
  role pins that secret empty and their boot gate rejects a non-empty value.
- **Loopback edge.** Container ports bind to `127.0.0.1` only; nginx is the sole
  reachable path. `TRUSTED_PROXIES=REMOTE_ADDR` is safe only under that
  invariant. Never publish 8080/8081 on a routable address.
- **Attested, digest-pinned image.** The release image is pinned by digest and
  its build provenance is verified (`gh attestation verify`) before deploy;
  `install.sh` and `deploy.sh` verify when `gh` is available.
- **Secret handling.** `install.sh` generates each secret independently
  (`openssl rand -base64 32`), writes env files `0600` under `umask 077`, and
  passes the admin password through stdin into the container rather than process
  arguments. `.gitignore` excludes `*.env` (except examples), `*.pem`, and the
  extracted DB CA.
- **PDF is opt-in and off by default.** PDF artifacts are production-capable but
  disabled unless the installer opt-in enables them. When enabled, the processor
  runs with `Network=none` reached only over a Unix socket, one replica, hard
  resource limits (512 MiB / 1 CPU / 32 PIDs), read-only rootfs, dropped
  capabilities, and a dedicated secret that non-app roles pin empty. Enabling PDF
  in production still requires completing the per-deployment enablement gate in
  `TESTING.md` and the release's `RELEASE-CHECKLIST.md`.

## Out of scope (you still own these)

- Host hardening, OS and nginx patching, firewalling, SSH access control.
- The documented, non-preventable residuals of running untrusted artifacts
  (see the ArtifactFlow `THREAT-MODEL.md`): navigation-based exfiltration is
  bounded by the isolated origin, not eliminated.
- Backup storage security and secret-manager custody of `APP_KEY`,
  `ARTIFACT_URL_SIGNING_KEY`, and `IMAGE_PARSER_SHARED_SECRET`.
- Any TLS proxy/CDN in front of nginx must also leave `Set-Cookie` absent on
  the artifact hostname.

## Review status

The Quadlet topology and env contract follow the ArtifactFlow `docs/OPERATIONS.md`
runtime contract for the pinned release. The shell scripts (`install.sh`,
`deploy.sh`) have been reviewed for secret handling, file permissions, and SQL
construction, but see `TESTING.md`: they must be run end-to-end on a fresh VM
before this kit is relied on in production.

## Reporting a vulnerability

- Vulnerabilities in **ArtifactFlow itself** (the application): follow the
  security policy in the [ArtifactFlow repository](https://github.com/Gadsotek/artifactflow).
- Vulnerabilities in **this deployment kit** (scripts, Quadlet units, docs):
  report privately to `14184492+Gadsotek@users.noreply.github.com`, or open a
  GitHub private security advisory, rather than a public issue.

Please do not include working exploits or secrets in reports.
