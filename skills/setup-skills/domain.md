# Domain Docs

How the engineering skills should consume this repo's domain documentation when
exploring the codebase. Skills read the pointers in the **Layout** section below —
they don't hardcode a file name — so this doc is the single place that describes
where domain knowledge lives.

## Layout

This repo uses **one** of the following. Keep the section that applies and delete
the others when `setup-skills` writes this file for a real repo.

### Single-context (most repos)

- **Vocabulary** — `CONTEXT.md` at the repo root (a glossary; see the `/domain-modeling` `CONTEXT-FORMAT.md`).
- **Decisions** — `docs/adr/`.

```
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-event-sourced-orders.md
│   └── 0002-postgres-for-write-model.md
└── src/
```

### Multi-context (presence of `CONTEXT-MAP.md` at the root)

- **Vocabulary** — `CONTEXT-MAP.md` at the root points at one `CONTEXT.md` per context. Read each one relevant to the topic.
- **Decisions** — `docs/adr/` (system-wide) plus `src/<context>/docs/adr/` (context-scoped).

```
/
├── CONTEXT-MAP.md
├── docs/adr/                          ← system-wide decisions
└── src/
    ├── ordering/
    │   ├── CONTEXT.md
    │   └── docs/adr/                  ← context-specific decisions
    └── billing/
        ├── CONTEXT.md
        └── docs/adr/
```

### OKF (Open Knowledge Format — the repo's chosen knowledge root)

The domain language lives in per-concept knowledge documents with progressive
indexes. When writing this configuration, replace `<knowledge-root>` with the
actual root from project instructions and existing docs; `docs/knowledge/` is
only the default. Preserve the bundle's declared version and authoring profile.

- **Vocabulary** — `<knowledge-root>/index.md`, then the relevant area indexes and concepts.
- **Decisions** — the repo's existing ADR convention: record the actual directory or tracker links here.
- **Optional supporting docs** — name an entity map, principles document or test scenario matrix only when the repo already maintains it. Use its actual path.

```
<knowledge-root>/
├── index.md
└── <area>/
    ├── index.md
    └── <concept>.md
```

An OKF library does not require an entity map, principles document, test matrix,
or a parallel `CONTEXT.md`. Reuse existing sources of truth and link them.

## Before exploring, read these

- The **Vocabulary** source(s) for the layout above.
- The **Decisions** in the declared files or tracker that touch the area you're about to work in.
- Relevant optional supporting docs listed above, when present.

If a supporting document does not exist, proceed without proposing it as a
prerequisite. Record resolved terminology through `/domain-modeling`; establish
or expand an OKF library through `/repo-knowledge`. Keep decisions in the repo's
chosen ADR location.

## Use the domain vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a
hypothesis, a test name), use the term as the domain docs define it — the glossary
entry (`CONTEXT.md`) or the relevant concept in the configured knowledge root
(and entity map, when present). Don't drift to synonyms the docs explicitly
avoid.

If the concept you need isn't in the domain docs yet, that's a signal — either
you're inventing language the project doesn't use (reconsider) or there's a real gap
(note it for `/domain-modeling`).

## Flag conflicts

If your output contradicts an existing **ADR**, surface it explicitly rather than
silently overriding:

> _Contradicts ADR-0007 (event-sourced orders) — but worth reopening because…_

When the repo maintains a principles document, do the same against an
**enforced** principle at its declared location:

> _Contradicts principle #2 (ledger entries are append-only), which is enforced by
> a DB trigger — flagging rather than overriding._

Only flag *enforced* principles this way; *aspirational* ones are guidance, not
guardrails.
