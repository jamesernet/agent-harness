# Reference taxonomy

What to extract from a doc, how to verify it, and how each type goes wrong.
`scripts/extract-refs.py` covers types 1–2 mechanically; the rest are yours.

Ordered by how often they rot.

## 1. Paths and directories

**Extract:** tree-diagram entries, backticked spans that look like paths,
relative markdown link targets, `@import` lines.

**Verify:** the staged resolver in SKILL.md. Stages A–C are exact; D–E are
recovery; F–G are exoneration.

**Fails as:** a file renamed or moved in a refactor while the module map kept
the old name.

**Traps:**
- Paths are usually relative to a tree block's root, not the repo root.
- Gitignored files (`.claude/settings.local.json`) exist but are not tracked.
- Marker and generated files (`.llmctx-managed.json`) never exist in the repo —
  the code creates them. Grep the sources before calling one broken.
- Historical prose ("was `users.py` until #713 renamed it") is a record, not a claim.

## 2. Globs and patterns

**Extract:** anything containing `*`, `?`, `<placeholder>`, `{a,b}`.

**Verify:** expand where cheap (`git ls-files '<glob>'`). A glob matching zero
files is a finding; one matching some is fine.

**Fails as:** "all tests live in `__tests__/`" after a move to co-located tests.

Mark as unverifiable rather than guessing when the placeholder is a real
variable (`docs/briefs/<issue-id>-<slug>.md`).

## 3. Commands and scripts

**Extract:** fenced shell blocks, backticked `npm run …` / `make …` / `./x.sh`,
and any "run this" instruction.

**Verify — never by running it:**

| form | check against |
|---|---|
| `npm run X` / `pnpm X` / `yarn X` | `scripts` in `package.json` |
| `make X` | `Makefile` targets |
| `./scripts/x.sh` | the file exists and is executable |
| `uv run X` / `poetry run X` | `pyproject.toml` |
| `bin/x` | the file exists |

**Fails as:** a script renamed in `package.json` while the README kept the old
name; or a whole toolchain swap (npm → pnpm) that left the docs behind.

A documented command may be destructive. Verification is a lookup, always.

## 4. Versions and toolchain

**Extract:** "we use Node 18", "Python 3.12", pinned tool versions, image tags.

**Verify:** `.nvmrc`, `engines` in `package.json`, `pyproject.toml`
`requires-python`, `.python-version`, `Dockerfile` base images, CI setup steps,
lockfiles.

**Fails as:** the doc pinning a version the CI matrix no longer builds. When the
doc and CI disagree, **CI is the truth** — it is what actually runs.

## 5. Symbols, env vars, config keys

**Extract:** named functions, classes, exported constants, `UPPER_SNAKE` env
vars, config keys the doc claims exist.

**Verify:** grep. For env vars also check `.env.example`, settings/config
modules, CI env blocks, and deployment templates.

**Fails as:** a renamed setting still documented under its old key — worse than
a broken path, because it fails silently at runtime rather than loudly at import.

## 6. Branches, CI jobs, external targets

**Extract:** branch names, workflow/job names, deploy targets, dashboard URLs.

**Verify:** `git branch -a` and `git symbolic-ref refs/remotes/origin/HEAD` for
branches; `.github/workflows/*.yml` for job names. Leave URLs unverified — do
not fetch them as part of an audit.

**Fails as:** docs still saying `master` after a rename to `main`; a referenced
CI job deleted in a workflow consolidation.

## 7. Architectural claims

**Extract:** universal statements — "all X go through Y", "every handler
returns Z", "nothing writes to W directly".

**Verify:** spot-check two or three real instances. Look hardest for the
counter-example; a single one disproves the claim.

**Fails as:** a rule that was true when written and has since grown exceptions
nobody documented. This is the highest-value class — the claim still reads as
authoritative and is quietly wrong.

Report as **SUSPECT** with the contradicting example cited, never as BROKEN.
The right fix is usually to weaken the claim ("most", "by convention") or to
name the exceptions.

## 8. ADRs

**Extract:** status field, date, the decision, and any "supersedes" /
"superseded by" links.

**Verify:** an ADR contradicted by the code, or superseded by a later ADR
without either being marked, is drift **in the status field**.

**Never treat a moved path inside an ADR as drift.** An ADR records what was
decided, in the layout of the day. Correcting its paths falsifies the record.

## 9. Briefs and handoffs

**Extract:** `docs/briefs/<issue-id>-<slug>.md`, `docs/briefs/handoffs/*.md`.

**Verify:** the issue's state on the tracker; whether the branch merged
(`git merge-base --is-ancestor`). Handoffs are meant to be deleted once absorbed.

**Fails as:** a brief for shipped work still read as pending. The remediation is
deletion or a status update, never a path patch.
