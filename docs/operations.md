# Operations

## Install and verify

Run `./install.sh` from a checked-out release, then `bin/llmctx doctor`. Installation owns the generated Claude/Codex adapters, the portable keys declared by `claude/settings.json`, marked skill copies, and this repository's installed Git-hook components. Personal permission keys, other unmanaged settings, and unmarked skill directories are preserved.

`doctor --json` is the stable machine-readable health interface. `doctor --quiet` emits nothing and communicates health only through its exit code.

Installation covers every registered Claude account, not only `~/.claude`. Register one with `bin/llmctx account add <name> <dir>` before installing; `~/.claude` is always covered as `default`. In `doctor --json`, the default account keeps the `claude-skills` check id and each additional account appears as `claude-skills[<name>]`, so existing consumers are unaffected and a lagging second account cannot hide behind an aggregate result.

## Update

Fetch tags, deliberately check out the desired release, run `install.sh`, then run `doctor`. Do not automate `git pull` against `main`. The workstation repository should choose the release; this repository should remain unaware of machine inventory and Git identities.

## Develop skills

Run `bin/llmctx skills install --dev` to replace managed copies with links into the current checkout. Return to release-like behavior with `bin/llmctx skills install`. Both modes preserve unrelated real directories and fail on name conflicts.

## Publish context

`bin/llmctx publish sync` updates marker-delimited public content in known, already-cloned consumer repositories. `--check` is read-only. Publication is never part of installation.

## Release

1. Run `bin/lint-skills.sh`, `bin/check-vendor-lock.sh`, and `tests/run.sh`.
2. Run `pre-commit run --all-files`.
3. Merge the reviewed change to `main`.
4. Create a signed `vMAJOR.MINOR.PATCH` tag on that exact tested commit.
5. Push `main` and the explicit tag ref, then verify both remote refs.
6. Let tag CI verify the tag and portable suite before workstation automation adopts it.

If `fetch.pruneTags=true` is configured, do not fetch between creating and
pushing a new tag: Git may prune the local-only tag because it does not exist on
the remote yet. Publish the signed tag first, then resume normal fetching.

Tags and branches are not created or pushed by repository scripts. Those
external Git actions remain explicit.

## Recovery

Re-running `install.sh` is idempotent and repairs stale managed files. If `doctor` reports a conflict, inspect it before removal: conflicts indicate content that is not marked as owned by agent-harness. For repositories using Husky, Lefthook, or another `core.hooksPath`, integrate the branch check through that framework rather than overwriting it.
