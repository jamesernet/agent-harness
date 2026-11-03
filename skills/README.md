# Skills

Personal skill set. Each skill is a flat directory with a `SKILL.md` (Claude Code does
**not** discover nested category folders), so the grouping below is organizational only.

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

## design and engineering
| skill | invoke | what it does |
|---|---|---|
| [codebase-design](codebase-design/) | auto | shared vocabulary for deep modules — module, interface, seam, adapter, depth, leverage, locality; the deletion test; supporting [DEEPENING](codebase-design/DEEPENING.md), [DESIGN-IT-TWICE](codebase-design/DESIGN-IT-TWICE.md) |
| [tdd](tdd/) | `/tdd` · auto | red/green in vertical slices, never all tests first; refactor candidates inline; supporting [tests](tdd/tests.md), [mocking](tdd/mocking.md) |
| [improve-codebase-architecture](improve-codebase-architecture/) | `/improve-codebase-architecture` | scan for shallow modules → HTML report of deepening candidates → grill the chosen one; supporting [HTML-REPORT](improve-codebase-architecture/HTML-REPORT.md) |
| [domain-modeling](domain-modeling/) | `/domain-modeling` · auto | sharpen the glossary and record ADRs inline as decisions land; flat, multi-context and OKF layouts; supporting [ADR-FORMAT](domain-modeling/ADR-FORMAT.md), [CONTEXT-FORMAT](domain-modeling/CONTEXT-FORMAT.md), [OKF-FORMAT](domain-modeling/OKF-FORMAT.md) |
| [interview-me](interview-me/) | `/interview-me` · auto | one question at a time with a recommended answer; "with docs" variant records ADRs and glossary via domain-modeling |
| [diagnosing-bugs](diagnosing-bugs/) | `/diagnosing-bugs` · auto | no hypothesis until a fast, red-capable feedback loop exists; minimise, rank falsifiable hypotheses, instrument with tagged logs, fix with a regression test |
| [docs-drift-audit](docs-drift-audit/) | `/docs-drift-audit` · auto | audit AGENTS.md/CLAUDE.md/README against the code with a staged resolver before calling anything broken; supporting [reference-taxonomy](docs-drift-audit/references/reference-taxonomy.md), [report-template](docs-drift-audit/references/report-template.md), [extract-refs.py](docs-drift-audit/scripts/extract-refs.py) |

## intake pipeline
Issue → triage → slices → worktree → implementation → handoff. All user-invoked.
Run `/setup-skills` once per repo first; the others read its `docs/agents/*.md`.

| skill | invoke | what it does |
|---|---|---|
| [setup-skills](setup-skills/) | `/setup-skills` | per-repo config: issue tracker, triage label vocabulary, domain doc layout, where briefs and handoffs go, worktree helper, merge proof |
| [triage](triage/) | `/triage` | issue/PR state machine: categorise, verify the claim, grill if needed, write agent-ready briefs; supporting [AGENT-BRIEF](triage/AGENT-BRIEF.md), [OUT-OF-SCOPE](triage/OUT-OF-SCOPE.md) |
| [to-issues](to-issues/) | `/to-issues` | break a plan into tracer-bullet vertical-slice issues; if the plan lives only in the conversation, first writes the parent PRD issue without interviewing |
| [grab](grab/) | `/grab` | issue → worktree → brief → implement (tdd, verify each criterion with evidence, `/code-review`, commit) → handoff, one motion; built for parallel sessions |
| [handoff](handoff/) | `/handoff` | compact the session into a handoff for the next agent, wherever this repo keeps them |

## website audit
| skill | invoke | scope |
|---|---|---|
| [site-visual-baseline](site-visual-baseline/) | `/site-visual-baseline` · auto | reproducible screenshot sets across viewports with URL-derived filenames; the settle sequence and capture traps |
| [product-ux-review](product-ux-review/) | `/product-ux-review` · auto | browser-driven interaction audit with declared review modes and evidence labels; escape/recovery, forms, keyboard, responsive, consistency; supporting [interaction-checklist](product-ux-review/references/interaction-checklist.md), [report-template](product-ux-review/references/report-template.md) |
| [metadata-audit](metadata-audit/) | `/metadata-audit` · auto | gated audit of a page's machine-readable layer: robots, canonical, AI-crawler posture, llms.txt, OG/Twitter, JSON-LD; supporting [decision-tree](metadata-audit/references/decision-tree.md), [schema-by-page-type](metadata-audit/references/schema-by-page-type.md), [report-template](metadata-audit/references/report-template.md), [inventory.py](metadata-audit/scripts/inventory.py) |
| [website-audit-package](website-audit-package/) | `/website-audit-package` · auto | compile capture, UX, perf and metadata findings into one client deliverable with three-state finding labels and a machine-written evidence layer |
| [shopify-storefront-review](shopify-storefront-review/) | `/shopify-storefront-review` · auto | a Shopify store's money and offer logic: the discount register, prices and stacking measured at a real cart, dead codes in live flows, claims on pages and in docs checked against Admin; decisions separated from defects; supporting [register-and-invariants](shopify-storefront-review/references/register-and-invariants.md), [report-template](shopify-storefront-review/references/report-template.md), [storefront-prices.sh](shopify-storefront-review/scripts/storefront-prices.sh) |
| [review-prose](review-prose/) | `/review-prose` · auto | review writing for an audience with a technical editor, a plain-voice editor and the target reader run independently, synthesised by agreement |

`web-perf` (vendored, Cloudflare) is the performance leg of this family.

## security and compliance
| skill | invoke | scope |
|---|---|---|
| [threat-model](threat-model/) | `/threat-model` · auto | one flow: Mermaid DFD with trust-zone subgraphs, STRIDE per crossing, ranked mitigations |
| [data-privacy-review](data-privacy-review/) | `/data-privacy-review` · auto | PII inventory, retention and deletion paths, DSAR readiness, processors including AI vendors, consent and pixels |
| [tech-due-diligence](tech-due-diligence/) | `/tech-due-diligence` · auto | investor / M&A / situation-review pass: architecture, codebase health, team, security posture, scalability, roadmap credibility; findings memo and risk register |

## payments and fintech
| skill | invoke | scope |
|---|---|---|
| [money-movement-review](money-movement-review/) | `/money-movement-review` · auto | payment-flow pass (state machine, idempotency, webhooks, failure modes, reconciliation hooks) carrying two rule sets: [MONEY](money-movement-review/MONEY.md) (minor units, currency, rounding, allocation, FX) and [LEDGER](money-movement-review/LEDGER.md) (double-entry, immutability, derived balances, settlement matching, breaks) |
| [pci-dss-scoping](pci-dss-scoping/) | `/pci-dss-scoping` · auto | card-data flow mapping, CDE shrinking, SAQ selection |
| [kyc-aml-review](kyc-aml-review/) | `/kyc-aml-review` · auto | IDV, screening, risk rating, monitoring, SAR workflow — trace one customer and one alert end to end |

## dropped
Everything below lives in git history if ever needed.

- `review` — 2026-07. `grab` uses the built-in `/code-review`. Not to be confused with `review-prose`, which reviews writing and deliberately declines code.
- `to-prd` — 2026-11, folded into `to-issues` as its "no parent issue yet" step.
- `implement` — 2026-11, folded into `grab` as its step 5.
- `money-modeling`, `payment-flow-review`, `ledger-and-reconciliation` — 2026-11, merged into `money-movement-review`.

## Attribution
Seeded from [mattpocock/skills](https://github.com/mattpocock/skills) (MIT,
© 2026 Matt Pocock). Full notice in [LICENSE.upstream](LICENSE.upstream). The design,
pipeline, tdd and domain-modeling families began there and have been adapted since; the
website-audit, security and fintech families are original.
