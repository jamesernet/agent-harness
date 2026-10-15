# agent-harness project instructions

## Purpose

This repository is the source of truth for portable agent behavior, shared
skills, managed Claude settings, and Git safety hooks. Machine setup and private
values belong in the workstation repository; project-specific rules belong in
their project repositories.

## Working rules

- Edit canonical files in this repository, never generated files under
  `~/.claude` or `~/.codex`.
- Preserve installer ownership boundaries: unmanaged settings and unmarked
  skill directories must survive installation.
- Treat `vendor/` as immutable upstream content. Update it only through
  `bin/update-vendor.sh` with an explicit tag or commit.
- Keep shell code portable across the supported macOS and Linux environments.
- Keep changes small and logically scoped. Do not combine skill, installer,
  policy, and release changes unless they are inseparable.

## Verification

Run these checks before considering a change complete:

```sh
bin/lint-skills.sh
bin/check-vendor-lock.sh
tests/run.sh
pre-commit run --all-files
```

Run `actionlint .github/workflows/ci.yml` when changing CI. Run
`bin/llmctx repo diff .` when changing repository-policy conventions.

## Work tracking

GitHub Issues are the source of truth. The brief is the issue, not a copy of
it, and a mid-flight handoff is a comment on that issue. This repository
declares `"briefs": "tracker"` in `.llmctx.json`, so there is deliberately no
mirror in the tree — do not create one. Working notes stay local and
uncommitted.
