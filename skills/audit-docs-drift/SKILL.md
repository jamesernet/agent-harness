---
name: audit-docs-drift
description: Audit AGENTS.md, CLAUDE.md, README and other instruction/context docs against the actual codebase and report where they have drifted. Use whenever the user asks to check for doc drift, stale docs, broken paths in docs, outdated instructions, config rot, or whether agent rules still match reality — and after large refactors, file moves, renames, or dependency changes. Also use proactively when you notice a doc referencing a file that does not exist.
---

# Docs Drift Audit

Find where a repo's instruction docs have stopped telling the truth, and report
it with evidence.

The docs in scope are the ones an agent or a new engineer *obeys*: `AGENTS.md`,
`CLAUDE.md`, `README.md`, `CONTRIBUTING.md`, `.claude/rules/*.md`. A wrong rule
there is worse than a missing one — it gets followed.

## Core principle: resolution before accusation

A drift auditor that cries wolf is run once and never again. The failure mode is
not missing drift, it is **inventing it**.

Docs write paths relative to an enclosing tree block or section, not to the repo
root. On a real 1,600-line `AGENTS.md`, a naive `test -e` over extracted paths
reported 14 missing files; 13 of them existed. That is the job: resolve
properly, then accuse.

Never report a reference as broken until it has failed every stage:

```
A  the enclosing tree block's path          app/ + core/ + db.py
B  literal, from the repo root              bin/worktree.sh
C  relative to the doc's own directory      docs/briefs/README.md
D  suffix match anywhere in the tree        admin/compliance.py -> app/api/v1/internal/admin/compliance.py
E  basename match anywhere                  jumio.py -> app/providers/kyc/vendors/jumio.py
F  present on disk but untracked            .claude/settings.local.json  (gitignored — not drift)
G  a literal string in tracked source       .llmctx-managed.json  (the code creates it — not drift)
```

Only when the basename appears nowhere is it **BROKEN**, and only then is a
`git log --diff-filter=D -- <path>` lookup worth spending to prove what happened.

Two distinctions that kill most remaining noise:

- **A bare filename is not a path claim.** "see `tokens.ts`" claims no location,
  so finding it elsewhere is not drift. Only a reference containing `/` can be
  wrong about *where* something is.
- **A link label is not a reference.** In ``[`docs/signal.md`](knowledge/docs/signal.md)``
  the target is correct; the label is prose.

## What is drift, and what is history

Not everything that fails to resolve is rot.

| kind | treatment |
|---|---|
| instruction docs (`AGENTS.md`, `CLAUDE.md`, rules) | full audit — these are obeyed now |
| **ADRs** | a superseded or contradicted *decision* is drift; a path that has since moved is **correct history**. Never "fix" a path inside an ADR |
| **briefs** (`docs/briefs/`) | drift when the issue is closed or the branch merged — the fix is deletion, not a patch |
| vendored/mirrored third-party docs | out of scope; their links describe someone else's site |
| `~/…`, `/etc/…` | name the machine, not the repo — unverifiable here |

## Process

### 1. Collect the doc set

Start from the live instruction docs, and follow `@import` chains to a fixpoint
(`CLAUDE.md` → `AGENTS.md` → `global/*.md`). An imported file is in scope.

`docs/**` is opt-in — ask, or pass `--include-docs`, because most of it is
record rather than instruction.

### 2. Extract and resolve

```sh
python3 scripts/extract-refs.py --json > /tmp/drift.json
python3 scripts/extract-refs.py            # human-readable summary
```

The script finds facts: it extracts references (tree entries, inline code,
links, imports) with their line numbers and runs the staged resolver above. It
does not assign severity and it does not know what matters. That is yours.

Read `references/reference-taxonomy.md` for what to check beyond paths —
commands, versions, symbols, env vars, and architectural claims — and how.

**Never execute a command to test it.** Verify `npm run typecheck` against
`package.json` scripts, `make deploy` against the `Makefile`, `./scripts/x.sh`
against the file. A documented command may be destructive.

### 3. Judge what the script cannot

Three things need a human-shaped call:

- **`MOVED`** — is the doc under-specified but harmless (`launch.py` when the
  file is `app/api/v1/games/launch.py`), or actually pointing somewhere wrong?
- **A systematic offset** — when many references in one doc share a single
  common prefix that resolves them all, the doc has a declared base path.
  Report it once, not N times.
- **Architectural claims** — "all API routes go through `middleware/auth`".
  Spot-check two or three real examples. A claim contradicted by the code is a
  finding even though nothing is missing.

### 4. Ask whether the rule should exist

The most valuable finding is not a wrong path — it is a rule describing a
workflow nobody follows any more. When a doc is stale because the *process*
changed, recommend rewriting or deleting the rule. Patching the path preserves
a rule that should die.

### 5. Report

Write the report using `references/report-template.md`.

Location: `docs/audits/<yyyy-mm-dd>-docs-drift.md` when `docs/` exists,
otherwise `docs-drift-report.md` at the repo root.

Findings carry the house shape used by `llmctx repo diff` —
`{id, status, expected, actual, source, remediation}` — with `source` as
`<doc>:<line>`, so a reader can go straight to the line.

Close with the counts (checked / broken / moved / unverifiable) and a proposed
patch set.

**Never edit docs without approval.** Offer the fixes as one reviewable diff.
