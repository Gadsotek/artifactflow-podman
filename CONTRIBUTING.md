# Contributing

Thanks for helping improve this deployment kit. It is deployment orchestration
for [ArtifactFlow](https://github.com/Gadsotek/artifactflow) on a single server
(rootless Podman, systemd Quadlet, nginx TLS edge). It ships no application
source; app-role containers run the attested release image by digest.

Please read `README.md` and `SECURITY.md` first, and the main repository's
`docs/OPERATIONS.md`, which is the runtime contract this kit implements.

## Ground rules

- **Security is the first constraint.** Do not weaken the invariants in
  `SECURITY.md`: two separate origins, host-only session cookie, loopback-bound
  container ports behind nginx, `DB_SSLMODE=verify-full`, the least-privilege
  artifact-host database role, and the internal-only image parser.
- **Never commit secrets.** No real `.env` files, private keys, certificates, or
  tokens. `.gitignore` already excludes `*.env` (except `*.env.example`),
  `*.pem`, and `db-ca.pem`; keep it that way.
- **Keep the pins consistent.** The release digest lives only in
  `quadlet/artifactflow-release.image`. If you bump it, also update
  `ARTIFACTFLOW_COMMIT` and the base digest in `Dockerfile.image-parser`, and
  every version reference in the docs. Verify the new digest with
  `gh attestation verify` before proposing the bump.

## Scope

In scope: fixes and improvements to the single-server Podman topology, the
scripts, the Quadlet units, the nginx vhosts, and the documentation; support for
new ArtifactFlow releases; portability across systemd distributions.

Out of scope: multi-node, Kubernetes, Docker Swarm, managed PaaS, or more than
one replica per role. Those are different deployments; this repo deliberately
models the single-VM case. Open an issue to discuss before large reworks.

## Making changes

- **Shell scripts** (`install.sh`, `deploy.sh`): keep `set -euo pipefail`, run
  `bash -n <script>` and `shellcheck <script>`, and preserve the safety
  behaviours (refuse to run as root, keep secrets out of process arguments,
  write env files `0600`).
- **Quadlet units and env examples**: keep role pins intact (empty parser/PDF
  secrets on non-app roles, `RUN_MIGRATIONS=0` on artifact-host). Add new
  required variables to the matching `env/*.example` with a safe default.
- **Docs**: if behaviour changes, update `README.md` and, where relevant,
  `GUIDE.html`.

## Testing

Any change to the scripts or units must be validated end-to-end on a throwaway
VM before it is proposed. Use `TESTING.md` as the checklist and note in your PR
what you ran, on which OS, Podman version, and release tag. Use only
non-sensitive test content.

## Commits and DCO

Keep commits focused and messages descriptive. Sign off every commit to certify
the [Developer Certificate of Origin](https://developercertificate.org/):

```sh
git commit -s -m "Your message"
```

## Pull requests

Fill in the PR template. A good PR states the objective, the in-scope change, and
the tests you ran, and keeps unrelated cleanups out. By contributing you agree
that your work is licensed under this repository's MIT `LICENSE`.

## Security issues

Do not open public issues for vulnerabilities. Follow `SECURITY.md`.
