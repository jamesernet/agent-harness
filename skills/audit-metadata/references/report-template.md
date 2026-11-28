# Report template

Use this structure. Verdict first — a client should get the answer before the evidence. Keep the
whole thing tight; a 40-page audit nobody reads is worth less than one page they act on.

Fill in real values from the page. Any `[...]` left in the output is a bug.

---

```markdown
# Metadata audit — [URL]
Audited [date] · [page type] · [what was and wasn't checked]

## Verdict
[Two or three sentences. Lead with the highest closed gate. If nothing is blocking,
say so — "nothing here prevents indexing or retrieval; the gaps are opportunity-level"
is a legitimate and useful verdict.]

**Highest closed gate:** [Gate N — name] or None

## Gate status

| Gate | Layer | Status |
|---|---|---|
| 0 | Reachable | ✅ / ⚠️ / ❌ / not checked |
| 1 | Crawlable & indexable | |
| 2 | AI crawler posture | |
| 3 | llms.txt | |
| 4 | Head identity | |
| 5 | Structured data | |
| 6 | Clean copy | |

## Findings

### P0 — Blocking
**[Finding]** · Gate [N]
What: [the observed fact, quoted from the page or file]
Why it matters: [the mechanism — what actually happens as a result]
Fix: [pointer to the fix block]

### P1 — Wrong
[same shape]

### P2 — Missing
[same shape]

### P3 — Polish
[one line each is fine here]

## Decisions for you, not defects
[Anything that looks like a finding but is a business choice — AI crawlers blocked,
intentional noindex, deprecated markup left in place. State the tradeoff and stop.
Omit this section entirely if there's nothing in it.]

## Search vs AI answer engines
[Only include when the two diverge. Two short lists. This is often the most
valuable section because it's the part nobody else separates.]

## Fixes

### robots.txt
```
[literal lines to add, remove, or change — with a comment on what each does]
```

### Head
```html
[literal tags]
```

### Structured data
```html
[complete replacement <script> block with real values from this page, wired with @id]
```

### llms.txt
```markdown
[drafted file, or "not recommended for this site type — here's why"]
```

### Copy changes
[Specific: "the pricing table in the hero is an image; the three tier names and
prices need to exist as HTML text." Not: "improve content quality."]

## Verify
- [ ] Rich Results Test on the changed URL
- [ ] validator.schema.org for vocabulary errors Google's tool won't flag
- [ ] `curl -sI [url] | grep -i x-robots` to confirm no header-level noindex
- [ ] the URL is present in the sitemap, and the sitemap still parses
- [ ] `curl -s [url] | grep -c "[a distinctive phrase from the body copy]"` to confirm
      content is server-rendered
- [ ] URL Inspection in Search Console after deploy
- [ ] [anything else specific to the findings above]
```

---

## Adjusting the shape

- **Nothing wrong?** Keep the verdict and gate table, drop the empty severity sections, and say
  what would be worth doing next anyway. Do not manufacture findings to fill the template.
- **User asked a narrow question** ("is my JSON-LD valid?") — answer it directly first, then offer
  the full walk. Don't force a seven-gate report on someone who asked one thing.
- **Multiple pages** — one gate table per page, then a shared findings section for anything
  template-level, since that's where the leverage is.
- **Non-technical audience** — keep the same order, drop the gate numbering, and replace
  mechanism explanations with consequences. "Search engines are being told not to list this page"
  rather than "X-Robots-Tag: noindex is present in the response headers."
