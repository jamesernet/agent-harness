# Skills

Personal, in-development skill set. Each skill is a flat directory with a `SKILL.md`
(Claude Code does **not** discover nested category folders), so the grouping below is
organizational only.

**Workflow:** these live in the `agent-harness` repo (version-controlled) and are installed
into each account's `skills/<name>/` by `bin/install-skills.sh` — managed copies by default,
symlinks under `--dev` so edits take effect immediately. A project-local `.claude/skills/` is
**additive**: it cannot hide a globally installed skill.

**Bundles:** [`bundles.conf`](bundles.conf) decides which skills a class of project actually
installs (`core`, `website`, `webapp`, `platform`, `fintech`, `cloudflare`, or `all`). Every
skill below must appear in at least one bundle — `bin/lint-skills.sh` enforces it, because a
skill in no bundle silently installs only under `all`.

`/name` = user-invocable. "auto" = can also self-trigger from the description's trigger phrases
(skills marked `disable-model-invocation: true` are user-invoked only).

## requirements
| skill | invoke | what it does |
|---|---|---|
| [to-prd](to-prd/) | `/to-prd` | turn the current conversation into a PRD on the issue tracker |
| [to-issues](to-issues/) | `/to-issues` | break a plan/PRD into independently-grabbable vertical-slice issues |
| [interview-me](interview-me/) | `/interview-me` · auto | relentless plan interview; "with docs" variant records ADRs + glossary via domain-modeling |

## engineering
| skill | invoke | what it does |
|---|---|---|
| [improve-codebase-architecture](improve-codebase-architecture/) | `/improve-codebase-architecture` | scan for deepening opportunities → HTML report → grill the chosen one |
| [implement](implement/) | `/implement` | implement work from a PRD or set of issues |
| [diagnosing-bugs](diagnosing-bugs/) | `/diagnosing-bugs` · auto | diagnosis loop for hard bugs and perf regressions |
| [docs-drift-audit](docs-drift-audit/) | `/docs-drift-audit` · auto | audit AGENTS.md/CLAUDE.md/README against the code; staged path resolution, ADR and brief rot; supporting [reference-taxonomy](docs-drift-audit/references/reference-taxonomy.md), [report-template](docs-drift-audit/references/report-template.md), [extract-refs.py](docs-drift-audit/scripts/extract-refs.py) |

## domain-modeling
| skill | invoke | what it does |
|---|---|---|
| [domain-modeling](domain-modeling/) | `/domain-modeling` · auto | build/sharpen the domain model; supporting [ADR-FORMAT](domain-modeling/ADR-FORMAT.md), [CONTEXT-FORMAT](domain-modeling/CONTEXT-FORMAT.md) |

## tdd
| skill | invoke | what it does |
|---|---|---|
| [tdd](tdd/) | `/tdd` · auto | red-green-refactor; supporting [tests](tdd/tests.md), [mocking](tdd/mocking.md), [refactoring](tdd/refactoring.md) |

## agent-handoff
| skill | invoke | what it does |
|---|---|---|
| [handoff](handoff/) | `/handoff` | compact the conversation into a handoff doc for another agent |
| [grab](grab/) | `/grab` | issue → worktree → brief → implement, one motion; built for parallel sessions |

## dependencies (pulled to close the graph)
These are referenced by the skills above; imported so the set is self-contained.
| skill | invoke | needed by |
|---|---|---|
| [codebase-design](codebase-design/) | auto | improve-codebase-architecture, tdd (module/seam/depth vocabulary) |
| [setup-skills](setup-skills/) | `/setup-skills` | to-prd, to-issues, triage (per-project tracker + label config) |
| [triage](triage/) | `/triage` | front-end of the intake→triage→prd→issues pipeline |

_`review` was dropped 2026-07 — `implement` uses the built-in `/code-review`; it lives in git history if ever needed. Not to be confused with `review-prose`, which reviews writing and deliberately declines code._

## product & UX (mine — not upstream)
| skill | invoke | scope |
|---|---|---|
| [product-ux-review](product-ux-review/) | `/product-ux-review` · auto | browser-driven UX audit; escape/recovery, forms, keyboard, responsive, consistency; supporting [interaction-checklist](product-ux-review/references/interaction-checklist.md), [report-template](product-ux-review/references/report-template.md) |
| [metadata-audit](metadata-audit/) | `/metadata-audit` · auto | gated audit of a page's machine-readable layer; robots/canonical/AI-crawler posture, llms.txt, OG/Twitter, JSON-LD; supporting [decision-tree](metadata-audit/references/decision-tree.md), [schema-by-page-type](metadata-audit/references/schema-by-page-type.md), [report-template](metadata-audit/references/report-template.md), [inventory.py](metadata-audit/scripts/inventory.py) |
| [site-visual-baseline](site-visual-baseline/) | `/site-visual-baseline` · auto | reproducible screenshot record across viewports; before/after evidence, capture traps |
| [website-audit-package](website-audit-package/) | `/website-audit-package` · auto | assemble screenshots, UX, perf and metadata findings into one client-ready package |
| [review-prose](review-prose/) | `/review-prose` · auto | review writing meant for an audience by running a technical editor, a plain-voice editor and the target reader independently, then synthesizing by agreement |

## payments & fintech (mine — not upstream)
| skill | invoke | scope |
|---|---|---|
| [money-modeling](money-modeling/) | `/money-modeling` · auto | minor units, decimals, currency, rounding, allocation, FX |
| [payment-flow-review](payment-flow-review/) | `/payment-flow-review` · auto | auth/capture/settle/refund states, idempotency, webhooks, reconciliation |
| [ledger-and-reconciliation](ledger-and-reconciliation/) | `/ledger-and-reconciliation` · auto | double-entry, immutability, balance derivation, settlement matching, breaks |
| [tech-due-diligence](tech-due-diligence/) | `/tech-due-diligence` · auto | architecture/team/risk/compliance diligence pass (investor · M&A · situation review) |

## security & compliance (mine — not upstream)
| skill | invoke | scope |
|---|---|---|
| [threat-model](threat-model/) | `/threat-model` · auto | DFD, trust boundaries, STRIDE, ranked mitigations |
| [data-privacy-review](data-privacy-review/) | `/data-privacy-review` · auto | PII inventory, retention/deletion, DSAR, residency, processors |
| [pci-dss-scoping](pci-dss-scoping/) | `/pci-dss-scoping` · auto | card-data flow mapping, CDE shrinking, SAQ selection |
| [kyc-aml-review](kyc-aml-review/) | `/kyc-aml-review` · auto | IDV, screening, risk rating, monitoring, SAR workflow |

## Attribution
Seeded verbatim from [mattpocock/skills](https://github.com/mattpocock/skills) (MIT,
© 2026 Matt Pocock). Full notice in [LICENSE.upstream](LICENSE.upstream). These are
starting points — adapt into your own voice/structure as you go.
