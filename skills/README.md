# Skills

Procedures a coding agent follows for a particular kind of work: how to review
a payment flow, how to audit a page's machine-readable layer, how to debug
something that only fails sometimes. Each is a directory with a `SKILL.md`
(the procedure) and sometimes `references/` (templates, checklists) and
`scripts/` (deterministic extraction the agent should not do by eye). They
load into Claude Code and Codex.

They grew out of one engineer's consulting practice — websites and storefronts,
a regulated gaming backend, technical due diligence — and they are opinionated
about method rather than about stack. Where a skill leans on something that
exists only in this practice, the section near the end says so.

## Using one skill without the rest

Copy the directory. Claude Code reads `~/.claude/skills/<name>/SKILL.md`;
Codex reads `~/.codex/skills/<name>/SKILL.md`. Nothing else in this repository
is required, and a skill that names another one works without it — the link
is a suggestion, not an import.

```sh
git clone https://github.com/jamesernet/agent-harness.git
cp -R agent-harness/skills/money-movement-review ~/.claude/skills/
```

Then describe the work in a session, or type `/money-movement-review`.

To install the set as versioned copies that survive moving this checkout, with
per-account selection and a drift check, use the harness: `./install.sh`, then
`bin/llmctx doctor`. [`bundles.conf`](bundles.conf) decides which skills a
class of project gets; see the bundles section below.

## Start here

The five that get used most. The count is a grep over Claude Code's local
session logs for explicit skill loads, late August to early November 2026; the
logs are not published. docs-drift-audit arrived in September, so its count
covers a shorter window than the others.

| skill | invoke | reach for it when |
|---|---|---|
| [codebase-design](codebase-design/) | auto | you are about to design or reshape a module's interface and want the deep-module vocabulary applied consistently |
| [tdd](tdd/) | `/tdd` · auto | you want a feature built test-first without the trap of writing every test before any code |
| [product-ux-review](product-ux-review/) | `/product-ux-review` · auto | a running web product needs an interaction audit whose findings a client cannot wave away |
| [docs-drift-audit](docs-drift-audit/) | `/docs-drift-audit` · auto | the instruction docs an agent obeys may no longer match the tree |
| [improve-codebase-architecture](improve-codebase-architecture/) | `/improve-codebase-architecture` | you suspect shallow modules and want the candidates ranked and argued, not listed |

## How a skill triggers

`/name` means a person types it. "auto" means the agent may load it from the
trigger phrases in the skill's description, so how that description is worded
does most of the work of making a skill fire. Skills marked
`disable-model-invocation` are slash-only on purpose. For `triage`, `to-issues`
and `grab` the reason is that they write to a tracker or start a branch, and
that should not happen because a sentence sounded like it; `setup-skills`,
`handoff` and `improve-codebase-architecture` are slash-only because each is a
deliberate session-level act rather than a reaction to a phrase.

Five skills pin an `effort` level. It is an override, not a floor: the skill
runs at that level whatever the session is set to, up or down. `threat-model`,
`tech-due-diligence`, `money-movement-review` and `shopify-storefront-review`
pin `xhigh`; `site-visual-baseline` pins `medium`, deliberately cheaper than
most sessions. Two name a managed subagent for their fan-out work so the model
and turn budget of that work has a default that travels with the skill:
`review-prose` and `improve-codebase-architecture`. The agents live in
[`../agents/`](../agents/README.md).

## The catalogue

Each row says what the skill focuses on and what it adds over asking the model
cold. If the second column reads as nothing, the skill should not exist.

### Design and engineering

For any codebase. Five of these share one vocabulary and call each other;
docs-drift-audit is the odd one out, auditing the docs the others read.

| skill | invoke | focus | what it adds |
|---|---|---|---|
| [codebase-design](codebase-design/) | auto | deep modules: module, interface, seam, adapter, depth, leverage, locality | the deletion test and "the interface is the test surface"; one language every other design skill reuses; supporting [DEEPENING](codebase-design/DEEPENING.md), [DESIGN-IT-TWICE](codebase-design/DESIGN-IT-TWICE.md) |
| [tdd](tdd/) | `/tdd` · auto | red/green in vertical slices | forbids writing all tests first; refactor candidates inline; records scenarios where the repo keeps a matrix; supporting [tests](tdd/tests.md), [mocking](tdd/mocking.md) |
| [improve-codebase-architecture](improve-codebase-architecture/) | `/improve-codebase-architecture` | scan for shallow modules, report, grill the chosen one | before/after diagrams per candidate, ADR-conflict awareness, a top recommendation rather than a list; supporting [HTML-REPORT](improve-codebase-architecture/HTML-REPORT.md) |
| [domain-modeling](domain-modeling/) | `/domain-modeling` · auto | glossary and ADRs maintained as decisions land | the three-part ADR gate (hard to reverse, surprising, a real trade-off) keeps ADRs rare; flat, multi-context and OKF layouts; supporting [ADR-FORMAT](domain-modeling/ADR-FORMAT.md), [CONTEXT-FORMAT](domain-modeling/CONTEXT-FORMAT.md), [OKF-FORMAT](domain-modeling/OKF-FORMAT.md) |
| [interview-me](interview-me/) | `/interview-me` · auto | one question at a time, each with a recommended answer | the primitive that `grab`, `triage` and the architecture review rely on; "with docs" records the answers as ADRs |
| [diagnosing-bugs](diagnosing-bugs/) | `/diagnosing-bugs` · auto | hard, flaky and performance bugs | no hypothesis until a fast, deterministic, red-capable command exists; then minimise, rank falsifiable hypotheses, instrument with tagged logs, fix with a regression test |
| [docs-drift-audit](docs-drift-audit/) | `/docs-drift-audit` · auto | AGENTS.md, CLAUDE.md, README against the tree | a seven-stage resolver before anything is called broken, so the report is trusted; supporting [reference-taxonomy](docs-drift-audit/references/reference-taxonomy.md), [report-template](docs-drift-audit/references/report-template.md), [extract-refs.py](docs-drift-audit/scripts/extract-refs.py) |

### Intake pipeline

Issue → triage → slices → worktree → implementation → handoff. All slash-only.
Run `/setup-skills` once per repo; the others read the `docs/agents/*.md` it
writes, so they never hardcode where a repo keeps its tracker, labels or briefs.

| skill | invoke | focus | what it adds |
|---|---|---|---|
| [setup-skills](setup-skills/) | `/setup-skills` | per-repo config: tracker, label vocabulary, domain-doc layout, where briefs and handoffs go, worktree helper, merge proof | reports what the repo already answers instead of asking cold; refuses to recreate a briefs directory a repo has retired |
| [triage](triage/) | `/triage` | issue and PR state machine | verifies the claim before grilling; writes agent-ready briefs; keeps a knowledge base of rejected requests; supporting [AGENT-BRIEF](triage/AGENT-BRIEF.md), [OUT-OF-SCOPE](triage/OUT-OF-SCOPE.md) |
| [to-issues](to-issues/) | `/to-issues` | a plan into tracer-bullet vertical-slice issues | writes the parent PRD issue from the conversation first when none exists, without interviewing |
| [grab](grab/) | `/grab` | issue → worktree → brief → implement → handoff in one motion | built for several sessions in parallel; verifies each acceptance criterion with evidence, not claims |
| [handoff](handoff/) | `/handoff` | compact the session for the next agent | puts the handoff where this repo keeps them, which differs per repo; redacts; points at artifacts rather than copying them |

### Website audit

For anything people look at. Four measure, one compiles, one reviews the
words. `web-perf` (vendored, Cloudflare) is the performance leg and installs
with this bundle.

| skill | invoke | focus | what it adds |
|---|---|---|---|
| [site-visual-baseline](site-visual-baseline/) | `/site-visual-baseline` · auto | reproducible screenshot sets across viewports | URL-derived filenames so a later run lines up file-for-file; the settle sequence and the capture traps that silently produce wrong screenshots |
| [product-ux-review](product-ux-review/) | `/product-ux-review` · auto | browser-driven interaction audit | evidence labels on every finding, so it says whether it was observed, inferred or guessed, and never a silent downgrade from runtime testing; supporting [interaction-checklist](product-ux-review/references/interaction-checklist.md), [report-template](product-ux-review/references/report-template.md) |
| [metadata-audit](metadata-audit/) | `/metadata-audit` · auto | robots, canonical, AI-crawler posture, llms.txt, structured data | gates, not checklists: a noindex page gets no schema advice; supporting [decision-tree](metadata-audit/references/decision-tree.md), [schema-by-page-type](metadata-audit/references/schema-by-page-type.md), [report-template](metadata-audit/references/report-template.md), [inventory.py](metadata-audit/scripts/inventory.py) |
| [shopify-storefront-review](shopify-storefront-review/) | `/shopify-storefront-review` · auto | a store's money and offer logic | builds the discount register the store usually lacks and measures stacking at a real cart, which is how a dead code in a live email gets found; supporting [register-and-invariants](shopify-storefront-review/references/register-and-invariants.md), [report-template](shopify-storefront-review/references/report-template.md), [storefront-prices.sh](shopify-storefront-review/scripts/storefront-prices.sh) |
| [website-audit-package](website-audit-package/) | `/website-audit-package` · auto | one client deliverable from several audits | three-state finding labels (live, fixed awaiting publish, open) and a machine-written evidence layer nobody hand-edits |
| [review-prose](review-prose/) | `/review-prose` · auto | writing meant for an audience | three reviewers run independently — a technical editor, a plain-voice editor, the actual target reader — synthesised by agreement; only the reader notices when a piece is well built and still changes nothing |

### Security and compliance

For anything that holds user data or money, and for the diligence that
precedes an engagement.

| skill | invoke | focus | what it adds |
|---|---|---|---|
| [threat-model](threat-model/) | `/threat-model` · auto | one flow: data-flow diagram, trust boundaries, STRIDE, ranked mitigations | Mermaid with one subgraph per trust zone so the artifact diffs; "unmitigated and unaccepted is not an allowed state" |
| [data-privacy-review](data-privacy-review/) | `/data-privacy-review` · auto | PII inventory, retention and deletion paths, DSAR, processors, consent | "a policy document without a cron job is a finding"; treats prompts to AI vendors as data transfers |
| [tech-due-diligence](tech-due-diligence/) | `/tech-due-diligence` · auto | investor, M&A or situation-review pass | one skeleton, three audiences; findings memo and ranked risk register; separates "expensive to reverse" from "not how I would do it" |

### Payments and fintech

Additive on top of another bundle. Each is a rule set with a review procedure
and a test checklist.

| skill | invoke | focus | what it adds |
|---|---|---|---|
| [money-movement-review](money-movement-review/) | `/money-movement-review` · auto | a payment flow end to end | the state machine drawn first and every failure mode walked; carries two rule sets — [MONEY](money-movement-review/MONEY.md) (minor units, currency, rounding, allocation, FX) and [LEDGER](money-movement-review/LEDGER.md) (double-entry, immutability, derived balances, reconciliation) |
| [pci-dss-scoping](pci-dss-scoping/) | `/pci-dss-scoping` · auto | cardholder-data flow, CDE, SAQ | "the goal is never pass PCI": shrink the environment until compliance is small |
| [kyc-aml-review](kyc-aml-review/) | `/kyc-aml-review` · auto | identity verification, screening, risk rating, monitoring, SAR workflow | traces one customer and one alert end to end; "screening at signup only" as the most common real finding |

## What depends on things outside this repository

Everything else is self-contained.

- **site-visual-baseline** prefers the Site Snapshot Explorer, an Emergent Labs
  tool, for the crawl and the contact sheet. Without it, the skill says how to
  drive Playwright to the same result; the traps are properties of the web, not
  of the tool.
- **review-prose** reads the author's voice guide, here `brand/voice-and-style.md`.
  Point it at your own; without one the reviewers propose a register that is
  not yours.
- **tech-due-diligence** names scoping and deliverable playbooks that live in a
  private repository. The procedure stands without them.
- **shopify-storefront-review** hands the machine layer to Site Scan, another
  Emergent Labs tool. `metadata-audit` and `web-perf` cover the same ground.
- **tech-due-diligence** also names the repository those playbooks live in; the
  name is the owner's own site, not a client.
- **The intake pipeline** assumes a tracker the `gh` or `glab` CLI can reach, or
  local markdown; `/setup-skills` asks which.

## Bundles

A project should not see every skill. `bundles.conf` names the sets; the
harness installs one per Claude account and prunes the rest.

| bundle | a project that is | adds |
|---|---|---|
| `core` | any codebase | design and engineering, the intake pipeline, plus metadata-audit because every project here ships a page somewhere and tech-due-diligence because it is the owner's first deliverable on any engagement |
| `website` | something people look at | core + the website audit family + data-privacy-review |
| `webapp` | a website that holds user data | website + threat-model |
| `platform` | a backend other things depend on | core + threat-model, data-privacy-review |
| `fintech` | somewhere money moves (additive) | the payments and fintech family |
| `cloudflare` | deployed there | the vendored Cloudflare set |

Every skill in this directory must appear in at least one bundle;
`bin/lint-skills.sh` enforces it.

## Vendored

`../vendor/` holds Cloudflare's own skills, pinned to an upstream commit in
`vendor.lock.json` and never edited here: `cloudflare`, `wrangler`,
`workers-best-practices`, `durable-objects`, `agents-sdk`, `sandbox-sdk`,
`cloudflare-email-service`, `cloudflare-one`, `cloudflare-one-migrations`,
`turnstile-spin`, `web-perf`. They keep their upstream licence.

## Dropped

Everything below lives in git history if ever needed.

- `review` — 2026-07. `grab` uses the built-in `/code-review`. Not to be confused with `review-prose`, which reviews writing and deliberately declines code.
- `to-prd` — 2026-11, folded into `to-issues` as its "no parent issue yet" step.
- `implement` — 2026-11, folded into `grab` as its step 5.
- `money-modeling`, `payment-flow-review`, `ledger-and-reconciliation` — 2026-11, merged into `money-movement-review`.

## Attribution and licence

The design, pipeline, tdd and domain-modeling families were seeded from
[mattpocock/skills](https://github.com/mattpocock/skills) (MIT, © 2026 Matt
Pocock; notice in [LICENSE.upstream](LICENSE.upstream)) and have been adapted
since. The website-audit, security and fintech families are original. Original
material is Apache-2.0; see [`../LICENSING.md`](../LICENSING.md) for the exact
boundary.
