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

Architecture decisions **extend** that rule rather than follow from it: an ADR
is an issue titled `ADR-NNN: <decision>`, not a file under `docs/`. The two are
not the same artifact — a brief is forward-looking and goes stale by design, an
ADR is a durable record meant to outlive the work — so this is a separate
decision that happens to land the same way, taken because #21 and #22 already
carry their context, decision and consequences in full and a file would be a
verbatim second copy.

Cite one by linking to it, so a reader has somewhere to go. The link needs
network access; it is clickable rather than offline-resolvable, which is the
cost of not keeping a copy.

An ADR issue closes once its decision is recorded and any work it describes has
landed; a superseded one closes with a comment naming what replaced it. Some
ADRs are also the ticket for their own implementation and legitimately carry
`ready` until that lands — so open-vs-closed tracks the work, not the standing
of the decision. Where the two could be confused, say which in the issue.
