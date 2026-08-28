<!-- Thanks for contributing. Keep the change focused and in scope. -->

## What and why

<!-- What does this change and why. Link any related issue. -->

## Type

- [ ] Fix
- [ ] Docs
- [ ] New ArtifactFlow release support (digest/pin bump)
- [ ] Portability / OS support
- [ ] Other:

## Checklist

- [ ] Stays in scope (single-VM Podman; not multi-node/k8s/Swarm/PaaS).
- [ ] Preserves the security invariants in `SECURITY.md` (two origins, host-only
      session cookie, loopback ports, DB `verify-full`, restricted artifact-host
      role, internal-only parser).
- [ ] No secrets, keys, or real `.env` files committed.
- [ ] Shell changes: `bash -n` and `shellcheck` pass; scripts still refuse to run
      as root and keep secrets out of process arguments.
- [ ] If bumping the release: digest, `ARTIFACTFLOW_COMMIT`, image-parser base
      digest, and all doc version references updated together; new digest
      verified with `gh attestation verify`.
- [ ] Docs updated (`README.md` and, if relevant, `GUIDE.html`).
- [ ] Validated end-to-end on a VM per `TESTING.md` (state what you ran below).
- [ ] Commits signed off (`git commit -s`, DCO).

## Test evidence

<!-- OS, Podman version, release tag, and what you ran / observed. -->
