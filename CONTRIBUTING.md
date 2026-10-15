# Contributing

Thanks for helping improve `agent-harness`. This repository contains portable,
public defaults for coding agents. Keep changes focused on behavior that is
safe and useful across machines and repositories.

For a small fix, open a pull request directly. For a substantial behavior,
policy, or interface change, start with an issue so the approach and ownership
boundary can be agreed before implementation. Report vulnerabilities through
the private process described in [SECURITY.md](SECURITY.md), not a public issue.

## Keep the public boundary intact

Do not add credentials, personal permissions, machine-specific identities,
private client details, or workstation configuration. Those values belong in a
private machine-configuration repository. Project-specific instructions belong
in the project that owns them.

Content under `brand/` is intentionally public but remains reserved personal
material. Original code, skills, and documentation are Apache-2.0; vendored
content retains its upstream terms. Read [LICENSING.md](LICENSING.md) before
changing or reusing content across those boundaries.

## Make changes at the source

- Edit canonical files in this repository, not generated files under
  `~/.claude` or `~/.codex`.
- Preserve settings and skill directories that the installer does not manage.
- Treat `vendor/` as immutable upstream content. Update it only with
  `bin/update-vendor.sh <tag-or-commit>`; floating branches are not accepted.
- Keep shell code portable across supported macOS and Linux environments.
- Keep each change small and limited to one concern.

## Verify the change

Run the full local checks before opening a pull request:

```sh
bin/lint-skills.sh
bin/check-vendor-lock.sh
tests/run.sh
pre-commit run --all-files
```

Also run `actionlint .github/workflows/ci.yml` after changing CI, and run
`bin/llmctx repo diff .` after changing repository-policy conventions.

In the pull request, explain the user-visible effect, the ownership boundary
affected, and the checks you ran. CI must pass on both macOS and Linux.
