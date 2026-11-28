# Decision tree

Walk top to bottom. Each gate says what to do when the thing is present, absent, or
contradictory. Stop-and-report means: everything below is still worth collecting, but state
clearly that it cannot take effect until this is fixed.

## Contents

- [Gate 0 — Reachable](#gate-0--reachable)
- [Gate 1 — Crawlable and indexable](#gate-1--crawlable-and-indexable)
- [Gate 2 — AI crawler posture](#gate-2--ai-crawler-posture)
- [Gate 3 — llms.txt](#gate-3--llmstxt)
- [Gate 4 — Head identity](#gate-4--head-identity)
- [Gate 5 — Structured data](#gate-5--structured-data)
- [Gate 6 — Clean copy](#gate-6--clean-copy)

---

## Gate 0 — Reachable

```
GET /robots.txt
├─ 200 ──────────────► parse; continue to Gate 1
├─ 404 or 410 ──────► treated as "everything allowed". Not an error.
│                     P3: add a minimal robots.txt anyway, mostly so the sitemap
│                     line has a home and AI-crawler policy has a place to live.
├─ 5xx (persistent) ► P0. Google's documented behaviour is to treat a persistently
│                     failing robots.txt as disallow-all. A broken server config here
│                     can deindex a whole site while every page looks perfect.
├─ 401/403 ─────────► P0. Same practical effect; crawler cannot establish permission.
└─ returns HTML ────► P1. A soft-404 robots.txt (SPA catch-all route serving index.html)
                      parses as garbage. Check Content-Type is text/plain.
```

Also at this gate: does the page itself return 200? A `noindex`-free page that 404s, redirects
in a chain, or returns 200 with an empty shell is a Gate 0 problem wearing a Gate 6 costume.

## Gate 1 — Crawlable and indexable

Crawlable and indexable are different. Confusing them produces the most common self-inflicted
wound in this whole audit.

```
Does a robots.txt Disallow rule match this URL path?
├─ yes ─► P0, stop-and-report.
│         Critical consequence to spell out: a disallowed URL is never fetched, so its
│         meta robots, canonical, hreflang and JSON-LD are all unread. If the user's goal
│         was to remove the page from the index, Disallow is the WRONG tool — it prevents
│         the crawler from ever seeing the noindex. Correct pairing:
│           • want it out of the index  → allow crawling + noindex
│           • want to save crawl budget → Disallow, accept it may still appear as a bare URL
└─ no ──► continue

Check meta robots AND the X-Robots-Tag response header:
├─ noindex present ─► P0 if unintended, "confirmed intentional" if not.
│                     Always ask which it is rather than assuming. Staging leaks and
│                     forgotten launch checklists both live here.
├─ nofollow site-wide ─► P2. Rarely what anyone means.
├─ noarchive / nosnippet / max-snippet:0 ─► P1 for AI visibility specifically.
│                     nosnippet suppresses the text an answer engine would quote.
│                     Frequently set years ago for reasons nobody remembers.
└─ none ─► default index,follow. Fine. Do not recommend adding an explicit
           index,follow tag; it does nothing.

Then discovery, which is a different question from permission — a page can be perfectly
crawlable and still never get found:

```
Sitemap
├─ no `Sitemap:` line in robots.txt and no /sitemap.xml ► P2. Not fatal; a well-linked
│    page still gets discovered. It removes the fastest discovery path and the only
│    lastmod signal a crawler gets for free.
├─ sitemap is not well-formed XML ► P1. A parse failure discards the whole file, so
│    every URL in it loses that discovery path at once, not just the broken entry.
├─ served as HTML — the SPA catch-all route again ► P1, same effect.
├─ audited URL absent from the sitemap ► P2 on a page that is meant to be indexed.
│    Check the boring cause first: a sitemap generated before the page existed and
│    never regenerated since.
├─ sitemap lists URLs that are noindex'd, canonicalised away, redirecting, or 404 ►
│    P2. The sitemap says "index this" while the page says "don't". No penalty, but
│    it wastes crawl budget and reliably means the sitemap is generated from the
│    wrong source of truth.
├─ `<loc>` values are relative ► P1. They must be absolute.
├─ lastmod absent, malformed, or set to the build timestamp on every URL ► P3. A
│    lastmod that changes on every deploy carries no information and gets discounted.
└─ it is a sitemap index ► the URL lives in a child sitemap. Fetch the relevant child
     before concluding anything is missing; the inventory script will not chase it.
```

CONTRADICTIONS to look for explicitly:
├─ Disallow + noindex on same URL ──────► P1, the noindex is unreachable
├─ canonical → URL A, but URL A canonicals → URL B ► P1 canonical chain
├─ canonical → a noindex'd URL ─────────► P1, dedupe target is unindexable
├─ canonical → a 404 or redirect ───────► P1
├─ self-referencing canonical missing on a page with query-param variants ► P2
├─ hreflang cluster without reciprocal return tags ► P1, cluster ignored
└─ hreflang pointing at canonicalised-away URLs ► P1
```

## Gate 2 — AI crawler posture

The question here is *intent*, not compliance. Determine what the site is currently saying to
answer engines and training crawlers, then ask whether that matches what the owner believes.

```
Search robots.txt for named AI user-agents.
├─ none named ──► default: all allowed. Report as an implicit position:
│                 "AI crawlers are currently allowed by default." Then ask whether
│                 that is intended. Many owners assume they are blocked and are not.
├─ blanket Disallow for AI UAs ──► NOT a defect. Report as a deliberate posture.
│                 If the same user is also asking why they aren't cited in ChatGPT,
│                 that's the finding: the two goals are in direct conflict.
└─ partial ──► the interesting case. Distinguish the two families, because blocking
               one and not the other is usually the coherent position:
                 • training / corpus:  GPTBot, ClaudeBot, CCBot, Google-Extended,
                                       Applebot-Extended, Bytespider, Meta-ExternalAgent
                 • answer / retrieval: OAI-SearchBot, ChatGPT-User, Claude-User,
                                       PerplexityBot, Perplexity-User, Bingbot
               Blocking training while allowing retrieval is a common and defensible
               stance: "don't train on me, do cite me." Flag when the split looks
               accidental instead — e.g. GPTBot blocked but CCBot wide open, which
               achieves close to nothing since Common Crawl feeds many corpora.

Then sanity-check the mechanism:
├─ AI UA rules placed after a `User-agent: *` block but relying on inheritance ►
│  P1. robots.txt groups do not inherit. A named agent obeys only its own group;
│  rules in the * group do not apply to it. This is the single most common
│  robots.txt authoring bug and it silently un-blocks everything.
├─ Crawl-delay used as the only throttle ► P3, honoured inconsistently.
├─ Blocking by UA string only ► note that UA is self-reported; real enforcement is
│  WAF/CDN-level, and robots.txt is a request, not a lock.
└─ No Sitemap: line ► P2.
```

## Gate 3 — llms.txt

Keep expectations calibrated. See the honesty note in SKILL.md — this is a P3 infrastructure
item, not a visibility lever.

```
GET /llms.txt
├─ 404 ──► P3. Recommend one if the site is documentation, an API, a developer tool,
│          or anything an agent might need to route through. Lower value for a
│          brochure site. Draft it in the fix block rather than describing it.
├─ 200 ──► validate the shape against the llmstxt.org convention:
│          ├─ starts with a single H1 (the site/product name)
│          ├─ a blockquote summary immediately after
│          ├─ H2 sections containing markdown link lists
│          ├─ links are absolute URLs and actually resolve ─► P1 if any 404
│          ├─ an "Optional" section for lower-priority links
│          └─ it is markdown, served as text/plain or text/markdown ─► P2 if served
│             as text/html with a full page wrapper, which defeats the purpose
├─ present but a plugin stub ──► P2. A large share of files in the wild are
│          auto-generated boilerplate listing every URL on the site. That is a
│          sitemap with extra steps and provides no curation value. The whole
│          point is editorial selection.
└─ per-page .md mirrors of every page ──► P1 if indexable. Mass markdown duplicates
           create real duplicate-content and crawl-budget problems. Either noindex
           them or don't generate them.
```

Do not confuse llms.txt with robots.txt AI directives. robots.txt grants or refuses access;
llms.txt offers a curated map to whoever already has access. A file that says
`User-agent: * Disallow: /` inside llms.txt is a category error — that syntax belongs in
robots.txt and means nothing in a markdown file. Flag it as P1 confusion if seen.

## Gate 4 — Head identity

```
├─ <html lang> missing ────────► P2. Cheap, and matters for both TTS and language targeting.
├─ <title> missing ───────────► P0-adjacent for search; the strongest single signal.
├─ <title> duplicated across templates ► P1
├─ <title> > ~60 chars ──────► P3 truncation risk, not an error
├─ meta description missing ──► P2. Not a ranking factor; it is CTR copy. Google
│                               rewrites it often. Worth having, not worth agonising over.
├─ meta description > ~160 ──► P3
├─ meta keywords present ────► P3 noise, ignored since ~2009, harmless. Mention once.
├─ canonical missing ────────► P2 (P1 on any page reachable via query params)
├─ og:title / og:description / og:image missing ► P2. Governs how the link renders
│                               in every share surface, which is often the real
│                               traffic path people were worried about.
├─ og:image not absolute URL ► P1, will not render
├─ twitter:card missing ─────► P3, most surfaces fall back to OG
└─ multiple conflicting viewport/charset declarations ► P3
```

## Gate 5 — Structured data

First establish *which syntax* is present, because the branches differ sharply.

```
Scan for: <script type="application/ld+json">, itemscope/itemtype, vocab/typeof
│
├─ JSON-LD present, parses cleanly ──────► best case, go to quality checks
├─ JSON-LD present, FAILS to parse ─────► P0 for the schema layer. An invalid block
│    is discarded whole and silently. The usual culprits, in order of frequency:
│      • a trailing comma before } or ]
│      • unescaped " inside a description, or smart quotes from a CMS
│      • a literal newline inside a string value
│      • a CMS template leaving {{ placeholder }} unrendered
│      • HTML comments or <!-- --> wrappers inside the script tag
│      • the block wrapped in CDATA
│    Report the exact character offset from the inventory script, not "there's an error".
├─ microdata or RDFa only ──────────────► P2. Valid and still parsed, but harder to
│    maintain and to extend. Recommend migrating to JSON-LD — it decouples markup from
│    presentation, so a template redesign can't break the data.
├─ both JSON-LD and microdata for the same entity ► P2. Pick one source of truth.
│    Two descriptions of the same product that disagree is worse than one.
└─ none at all ─────────────────────────► severity depends on page type:
     • Product / LocalBusiness / Event / Recipe / JobPosting page → P1, real
       display features are being left on the table
     • Article / BlogPosting → P2
     • generic marketing page → P3, though sitewide Organization is still worth it
     Emit a complete minimum block in the fix section. See schema-by-page-type.md.

QUALITY CHECKS, once it parses:
├─ @context missing or not https://schema.org ► P0 for that block
├─ @type misspelled or wrong case ───────────► P0 for that block. Types are
│    case-sensitive: BlogPosting not Blogposting, LocalBusiness not Localbusiness.
├─ required properties for the type missing ─► P1. Worth stating the mechanic
│    explicitly: a missing required property suppresses the ENTIRE rich result,
│    not just the field. There is no partial credit.
├─ recommended properties missing ───────────► P2
├─ entities are isolated islands with no @id ► P2. Without @id, Organization,
│    WebSite, WebPage and Article are four unrelated assertions rather than one
│    connected graph. Wiring them is the difference between "this page mentions a
│    company" and "this page is by this company." Highest-leverage fix for
│    entity disambiguation in AI answers.
├─ markup describes content not visible on the page ► P1 ALWAYS. Spam-policy
│    territory; consequence is a manual action, not a missed opportunity. Most
│    common form: review/rating markup on a page with no reviews on it.
├─ values disagree with visible copy (price, availability, date, author) ► P1
├─ dates not ISO 8601, or dateModified in the future ► P1
├─ image referenced in schema is not on the page, or is a 404 ► P1
├─ sameAs absent on Organization/Person ► P2 for AI specifically. sameAs links to
│    Wikipedia/Wikidata/LinkedIn/Crunchbase are how a model resolves "which Acme".
├─ betting the strategy on a deprecated rich-result type ► P2 recalibration, not a
│    code fix. The markup is fine; the expectation is wrong. See the status table.
└─ schema injected client-side by JS only ► P1 for non-Google consumers. Google
     renders; most LLM retrieval pipelines and social scrapers do not. Server-render it.
```

## Gate 6 — Clean copy

This gate is where AI retrievability is mostly won or lost, and it is the one most often
skipped in favour of tags.

```
├─ zero or near-zero text in raw HTML, content injected by JS ► P1 for LLM
│    retrieval. Test by diffing `curl` output against the rendered DOM. If the
│    body copy only exists post-hydration, most retrieval crawlers see an empty page.
├─ no <h1>, or more than one ─────► P2 / P3 respectively. Multiple h1s are legal
│    in HTML5 and not a real problem; a missing one is a genuine loss of the
│    page's own statement of what it is about.
├─ heading levels skipped (h2 → h4) ► P3. Mostly an accessibility and outline
│    concern; breaks the document tree used for chunking.
├─ headings used for styling rather than structure ► P2. An <h3> chosen because it
│    looked the right size scrambles the outline.
├─ div soup — no <main>, <article>, <nav>, <header>, <footer> ► P2. Semantic
│    landmarks are how an extractor separates content from chrome. Without them,
│    boilerplate gets pulled in as if it were the article.
├─ boilerplate-to-content ratio very high ► P2, dilutes every chunk.
├─ images missing alt ────────────► P2 accessibility first, secondarily descriptive text.
├─ data laid out with divs and CSS grid instead of <table> ► P2. A real table
│    with <th> survives extraction; a visual grid does not.
├─ pronoun-and-vibes copy: "our platform", "we help teams" without ever naming
│    the entity ► P2 for AI answers. A model cannot cite a company it cannot name.
│    Name the product, the company, and the category in plain text at least once
│    near the top.
├─ chunks that don't stand alone — a section that only makes sense after reading
│    the two above it ► P2. Retrieval lifts fragments. Front-load the answer,
│    then elaborate.
├─ keyword stuffing or repeated near-identical paragraphs ► P1 quality signal
└─ critical claims only in images (pricing in a JPEG, specs in a screenshot) ► P1.
     Invisible to every text pipeline. Duplicate in HTML text.
```
