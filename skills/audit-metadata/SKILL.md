---
name: audit-metadata
description: Walk a web page or site's machine-readable layer — robots.txt, meta robots, canonical, AI-crawler directives, llms.txt, JSON-LD / microdata structured data, and copy cleanliness — and produce a gated, severity-ranked findings report with copy-paste fixes. Use this whenever the user mentions a metadata walk, meta tags, schema markup, structured data, JSON-LD, rich results, robots.txt, llms.txt, canonical tags, crawlability, indexability, AI/LLM visibility, AEO/GEO, "why isn't this page showing up", or asks to audit, check, review, or clean up a page's tags, head section, or markup — even if they don't use the word "audit" and even if they only paste a URL or a chunk of HTML and ask what's wrong with it.
---

# Metadata Audit

A gated walk through the machine-readable layer of a page. The point is not to dump every
possible finding — it is to find the *highest gate that is closed*, because a page blocked in
robots.txt does not care how good its JSON-LD is.

## Core principle: gates, not checklists

The layers depend on each other. Report them in dependency order and say plainly when a
downstream finding is moot:

```
Gate 0  Reachable      → can a crawler get the file at all?
Gate 1  Crawlable      → is this URL allowed and indexable?
Gate 2  AI posture     → are AI/answer crawlers allowed, and is that intentional?
Gate 3  Agent surface  → llms.txt present and well-formed?
Gate 4  Head identity  → title, description, canonical, OG/Twitter, lang
Gate 5  Structured data→ which syntax, is it valid, is it complete, is it wired
Gate 6  Clean copy     → is the text extractable and self-contained
```

Still *collect* everything — a client wants the full picture — but order the report by gate and
mark anything below a closed gate as "blocked by Gate N". Handing someone twelve schema tweaks
when their page is `noindex` wastes their week.

## Workflow

### 1. Get the inputs

Three things, in order of value:

| Input | How to get it | If unavailable |
|---|---|---|
| Rendered/raw HTML of the target page | `web_fetch` the URL, or `curl -sL`, or read a file the user pasted/uploaded | Ask for a view-source paste |
| `/robots.txt` | fetch `{origin}/robots.txt` | Note as unverified — do not assume |
| Response headers | `curl -sIL {url}` | Note as unchecked — `X-Robots-Tag` is then unknown, not absent |
| `/sitemap.xml` | the `Sitemap:` line in robots.txt, else `{origin}/sitemap.xml` | Skip the discovery checks in Gate 1 |
| `/llms.txt` (and `/llms-full.txt`) | fetch both | Record as 404 only if actually checked |

The header dump earns a row of its own for a reason: `X-Robots-Tag` lives only there and is
invisible to every HTML-only check. A `noindex` in a header is the single most commonly missed
blocker.

If the sandbox has no outbound network, say so once and work from whatever the user can paste
rather than guessing. Never fabricate the contents of a robots.txt.

### 2. Run the inventory script

Deterministic extraction belongs in code, not in eyeballing:

```bash
python3 scripts/inventory.py page.html --url https://example.com/page \
  --robots robots.txt --headers headers.txt --sitemap sitemap.xml --llms llms.txt
```

It emits JSON: head tags with lengths, every JSON-LD block parsed (with the exact parse error
if one fails), `@type`/`@id` inventory with definitions separated from references, microdata and
RDFa presence, the robots.txt verdict for this path resolved by RFC 9309 precedence, sitemap
membership, response-header directives, heading outline, alt-text coverage, word counts, and a
`checks` block of pre-computed booleans. Stdlib only, no installs.

One thing the JSON will not do for you: `path_access` splits `general_crawler` from `ai_agents`
because they answer different gates. A blocked `GPTBot` is a Gate 2 posture question, never a
Gate 1 blocker.

Read the JSON, then apply judgment on top of it. The script finds facts; the gates and severities
are the analysis.

### 3. Walk the gates

Full branch logic — including what to do for every "missing" case — is in
`references/decision-tree.md`. Read it before writing findings.

Per-page-type schema requirements, current Google rich-result eligibility, `@id` graph wiring
patterns, and the mistakes that silently kill a valid-looking block are in
`references/schema-by-page-type.md`. Read it whenever Gate 5 is in play.

### 4. Assign severity

| | Meaning | Test |
|---|---|---|
| **P0** | Blocks indexing or retrieval outright | Fix this or nothing else matters |
| **P1** | Present but wrong — actively misleading or self-defeating | Could trigger suppression or a manual action |
| **P2** | Missing opportunity | Would add capability if added |
| **P3** | Polish | Real but low-leverage |

Two things that look like defects but are decisions, not bugs — flag them as choices and let the
owner rule, never "fix" them silently:

- AI crawlers disallowed in robots.txt. That may be a deliberate licensing or bandwidth
  position. A publisher blocking `GPTBot` is not making a mistake.
- `noindex` on staging, thank-you pages, faceted URLs, or paginated archives. Usually correct.

### 5. Write the report

Use the template in `references/report-template.md` exactly. Its shape matters: verdict first,
then the gate table, then findings ordered by gate, then a single copy-paste fix block.

The fix block is the deliverable people actually use. Give corrected code, not descriptions of
corrected code — a full replacement JSON-LD `<script>`, the literal robots.txt lines, a drafted
`llms.txt`. Use the real values from the page, not `[YOUR TITLE HERE]` placeholders.

## Judgment notes

**Search engines and answer engines want different things.** Split recommendations when they
diverge. Rich-result eligibility is a Google display question. Retrievability by an LLM is a
question of whether clean text exists in the raw HTML, whether the entity is named explicitly
instead of as "we" and "our platform," and whether a chunk makes sense lifted out of context.
A page can be flawless on one axis and useless on the other.

**Schema is not a ranking factor.** Say so if the user implies otherwise. It controls
eligibility for display features and helps machines disambiguate entities. Overpromising here
is the most common way these audits lose credibility.

**Markup must match visible copy.** Structured data describing content a human cannot see on the
page is a spam-policy violation, not a clever optimization. This is P1 every time, and it is
worth stating why: the downside is a manual action, not a missed opportunity.

**Rich-result support changes.** As of mid-2026, FAQ rich results were removed in May 2026 and
HowTo back in 2023 — both still-valid schema.org types that produce zero Google display lift.
Sitelinks Searchbox went in November 2024. `references/schema-by-page-type.md` carries the
current table, but it will drift: when a recommendation hinges on whether a type still earns a
rich result, verify against Google Search Central rather than asserting from memory.

**llms.txt deserves honesty.** It is a community proposal with no standards-body backing. As of
2026 no major provider has committed to reading it, adoption sits around one site in ten, and
Google has said on the record it does not support it. It is still cheap and reasonable to ship
for agent routing and documentation surfaces — recommend it as P3 infrastructure, and do not let
a client believe it will move rankings. Getting this wrong in either direction (dismissing it, or
selling it) damages trust.

**Scope honestly.** One page is one page. If the user says "the site," audit a representative
sample — home, a template page of each major type, one deep page — and label it as a sample.
Sitewide claims from a single URL are how audits get embarrassing.
