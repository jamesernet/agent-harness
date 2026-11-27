---
name: domain-modeling
description: Build and sharpen a project's domain model. Use when the user wants to pin down domain terminology or a ubiquitous language, record an architectural decision, or when another skill needs to maintain the domain model.
---

# Domain Modeling

Actively build and sharpen the project's domain model as you design. This is the *active* discipline — challenging terms, inventing edge-case scenarios, and writing the domain docs and decisions down the moment they crystallise. (Merely *reading* the domain docs for vocabulary is not this skill — that's a one-line habit any skill can do. This skill is for when you're changing the model, not just consuming it.)

## File structure

Discover the repo's chosen layout from project instructions and existing docs;
`docs/agents/domain.md` records it where `setup-skills` has been used. Common
layouts include:

**Single-context** — a flat `CONTEXT.md` glossary at the root:

```
/
├── CONTEXT.md
├── docs/
│   └── adr/
│       ├── 0001-event-sourced-orders.md
│       └── 0002-postgres-for-write-model.md
└── src/
```

**Multi-context** — a `CONTEXT-MAP.md` at the root pointing at per-context `CONTEXT.md` files:

```
/
├── CONTEXT-MAP.md
├── docs/
│   └── adr/                          ← system-wide decisions
├── src/
│   ├── ordering/
│   │   ├── CONTEXT.md
│   │   └── docs/adr/                 ← context-specific decisions
│   └── billing/
│       ├── CONTEXT.md
│       └── docs/adr/
```

**OKF** — per-concept docs under the chosen knowledge root (commonly
`docs/knowledge/`), with progressive indexes. Some repos also maintain an entity
map at `docs/architecture/domain-model.md`:

```
/
├── docs/
│   ├── knowledge/{index.md, <area>/{index.md, <concept>.md}}
│   ├── architecture/{domain-model.md, principles.md}
│   └── adr/{README.md, NNN-slug.md}
└── src/ (or app/)
```

Create files lazily — only when you have something to write. In flat repos, create
`CONTEXT.md` when the first term is resolved; in OKF repos, create the first
concept doc (see below). Follow the repo's ADR convention, including tracker-based
decisions; create `docs/adr/` only when file-based ADRs are its chosen convention.

## During the session

### Challenge against the domain docs

When the user uses a term that conflicts with the existing language in the domain docs (the `CONTEXT.md` glossary, or an OKF concept doc / the `domain-model.md` entity map), call it out immediately. "Your docs define 'cancellation' as X, but you seem to mean Y — which is it?"

### Sharpen fuzzy language

When the user uses vague or overloaded terms, propose a precise canonical term. "You're saying 'account' — do you mean the Customer or the User? Those are different things."

### Discuss concrete scenarios

When domain relationships are being discussed, stress-test them with specific scenarios. Invent scenarios that probe edge cases and force the user to be precise about the boundaries between concepts.

### Cross-reference with code

When the user states how something works, check whether the code agrees. If you find a contradiction, surface it: "Your code cancels entire Orders, but you just said partial cancellation is possible — which is right?"

### Update the domain docs inline

When a term is resolved, record it in the repo's domain docs right there. Don't batch these up — capture them as they happen. Which file, and in what format, depends on the layout (see `docs/agents/domain.md`):

- **Flat repos (`CONTEXT.md` / `CONTEXT-MAP.md`)** — update the glossary using the format in [CONTEXT-FORMAT.md](./CONTEXT-FORMAT.md). `CONTEXT.md` should be totally devoid of implementation details — it is a glossary and nothing else. Don't treat it as a spec, a scratch pad, or a repository for implementation decisions.
- **OKF repos (`docs/knowledge/`)** — refine the existing concept doc, or create a new one plus its index links, using the format in [OKF-FORMAT.md](./OKF-FORMAT.md). If the resolved term is a new domain *entity* and the repo already maintains an entity map, also update that map. OKF concept docs deliberately carry how-it-works detail (fields, lifecycles, tables) — the "glossary only" rule above does **not** apply to them; that constraint is specific to flat `CONTEXT.md`.

### Offer ADRs sparingly

Only offer to create an ADR when all three are true:

1. **Hard to reverse** — the cost of changing your mind later is meaningful
2. **Surprising without context** — a future reader will wonder "why did they do it this way?"
3. **The result of a real trade-off** — there were genuine alternatives and you picked one for specific reasons

If any of the three is missing, skip the ADR. Use the format in [ADR-FORMAT.md](./ADR-FORMAT.md).
