# Report template

Copy the block below. Drop sections that have no findings rather than writing
"none" under each — an empty audit should be short.

Statuses come from `llmctx repo diff` so drift findings read like every other
finding in these repos. Severity is about consequence, not count.

---

# Docs drift audit — [repo]

**Date:** [yyyy-mm-dd] · **Commit:** [short sha] · **Docs audited:** [n]

## Verdict

[Two or three sentences. Are the instruction docs trustworthy right now? If an
agent followed them today, what would go wrong? Lead with the worst thing.]

## Coverage

| | |
|---|---|
| references checked | [n] |
| resolved clean | [n] |
| broken | [n] |
| moved / under-specified | [n] |
| suspect claims | [n] |
| unverifiable | [n] |
| docs in scope | [list] |
| **not** audited | [ADRs, vendored mirrors, docs/** — say so explicitly] |

State what was skipped. A silent exclusion reads as "covered everything".

## Findings

Ordered by severity. Each carries where it is, what the doc claims, what is
actually true, and the fix.

### P0 — Actively misleading

An agent or engineer following this today does the wrong thing.

- **[id]** `[doc]:[line]` — **BROKEN**
  - **claims:** `path/or/rule/as/written`
  - **actual:** [what is true — with the commit that changed it, if known]
  - **fix:** [concrete edit, or "delete this rule"]

### P1 — Wrong but recoverable

Wrong, but the reader would notice before acting on it.

### P2 — Under-specified

Resolves, but only by luck or by search.

- **[id]** `[doc]:[line]` — **MOVED**
  - **claims:** `launch.py`
  - **actual:** `app/api/v1/games/launch.py`
  - **fix:** qualify the path

### P3 — Cosmetic

Stale wording, dead cross-references, formatting rot.

## Suspect claims

Architectural statements the code contradicts. Cite the counter-example — a
claim is only disproved by an instance.

- **[id]** `[doc]:[line]` — **SUSPECT**
  - **claim:** "all API routes go through `middleware/auth`"
  - **counter-example:** `[file:line]`
  - **fix:** weaken the claim, or name the exception

## Rules that should not be patched

Where the *workflow* changed, not the path. Patching these preserves a rule that
should be deleted or rewritten. This section is usually the most valuable one.

- **[id]** `[doc]:[line]` — [what the rule assumes, and why that is no longer
  how the work happens] → **recommend: rewrite / delete**

## Decisions for you, not defects

Things that cannot be settled mechanically, listed so they are not mistaken for
clean. Placeholders, external URLs, machine paths, generated files, and claims
that need someone who knows the intent.

## Proposed patch set

The fixes above as one reviewable change.

```diff
[unified diff]
```

Out of scope for this diff: [ADR paths — history, not drift; anything needing a
product decision].

## Verify

How to confirm the fixes hold:

```sh
python3 scripts/extract-refs.py            # broken should be 0
```

[Plus any repo-specific check — lint, tests, `llmctx repo diff .`]
