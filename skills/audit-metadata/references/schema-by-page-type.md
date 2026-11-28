# Schema by page type

## Contents

- [Rich-result status table](#rich-result-status-table)
- [Minimum viable sets by page type](#minimum-viable-sets-by-page-type)
- [Graph wiring with @id](#graph-wiring-with-id)
- [Silent killers](#silent-killers)

---

## Rich-result status table

Two different questions get conflated constantly. Keep them apart in the report:

1. **Is the type valid schema.org?** Almost always yes. Validity is cheap.
2. **Does it earn a visible Google feature?** Much narrower, and it shrinks over time.

Status as of mid-2026. Google prunes this list regularly — when a recommendation depends on
current eligibility, verify against Google Search Central rather than trusting this table.

| Type | Google display feature | Note |
|---|---|---|
| Product / Offer | Yes | Merchant listings + product snippets |
| Review / AggregateRating | Yes | Only where genuinely present on-page |
| BreadcrumbList | Desktop only | Lost mobile display Jan 2025 |
| Video / VideoObject | Yes | |
| Event | Yes | |
| Recipe | Yes | |
| JobPosting | Yes | |
| LocalBusiness | Yes | Feeds business panels |
| Organization | Yes | Brand identity, knowledge panel support |
| Article / BlogPosting / NewsArticle | Yes | Author, dates, carousels |
| Course (list) | Yes | Course *Info* was retired 2025; Course *list* was not |
| **FAQPage** | **No — removed May 2026** | Still valid markup. Leave existing in place; stop recommending it for new work. QAPage is a different type and still supported. |
| **HowTo** | **No — removed 2023** | Valid schema, zero display lift |
| **Sitelinks Searchbox** | **No — removed Nov 2024** | `WebSite` + `SearchAction` no longer renders a search field |
| ClaimReview, EstimatedSalary, LearningVideo, SpecialAnnouncement, VehicleListing, Practice Problem | No — retired 2025–26 | |

Deprecated markup causes no errors and no penalty. Removing it is optional and never urgent —
say that plainly so nobody spends a sprint ripping out FAQPage blocks. What *should* change is
the strategy that was resting on it.

Worth adding for the AI-answer axis regardless of Google display status: `sameAs`,
`Organization`, `Person` with credentials, and `about`/`mentions` do work for entity
disambiguation even where no rich result exists. Schema's value did not end with the rich result.

## Minimum viable sets by page type

Required means Google suppresses the whole feature without it. Recommended means it improves
eligibility or machine understanding.

### Organization — sitewide, emitted once (usually homepage)
- Required: `name`, `url`
- Recommended: `logo` (ImageObject, ≥112×112), `sameAs` (Wikipedia, Wikidata, LinkedIn,
  Crunchbase, GitHub — whichever are real), `description`, `contactPoint`, `foundingDate`,
  `address`
- `sameAs` is the highest-leverage property on this list for AI answers. It is how a model
  resolves which "Apex Systems" you are.

### Article / BlogPosting / NewsArticle
- Required: `headline` (≤110 chars), `image`, `datePublished`, `author`
- Recommended: `dateModified`, `publisher` (→ Organization `@id`), `description`,
  `mainEntityOfPage`, `articleSection`, `wordCount`
- `author` must be a `Person` or `Organization` object, never a bare string. A `Person` with
  `@id`, `url`, `jobTitle` and `sameAs` is the difference between an attributed byline and a
  name-shaped string.
- `headline` over 110 characters risks the whole block being ignored.

### Product
- Required: `name`, `image`, plus `offers` **or** `review` **or** `aggregateRating`
- `offers` (Offer) required: `price`, `priceCurrency`, `availability` (schema.org URL form,
  e.g. `https://schema.org/InStock`), `url`
- Recommended: `description`, `sku`, `gtin13`/`mpn`, `brand`, `priceValidUntil`,
  `shippingDetails`, `hasMerchantReturnPolicy`
- Return-policy markup now requires `returnPolicyCountry` (two-letter ISO code) — a genuine
  markup requirement change, not a display change, so blocks written earlier may be incomplete.
- Price and availability in the markup must match what a human sees. Stale prices from a cached
  template are a P1.

### LocalBusiness (use the most specific subtype: Restaurant, Dentist, AutoRepair…)
- Required: `name`, `address` (full PostalAddress)
- Recommended: `telephone`, `openingHoursSpecification`, `geo`, `url`, `priceRange`,
  `image`, `sameAs`, `areaServed`
- Multi-location: one page per location, each with its own `@id`, not one page listing twelve.

### WebSite / WebPage
- `WebSite`: `name`, `url`, `publisher` → Organization `@id`
- `WebPage`: `@id` (the canonical URL + `#webpage`), `isPartOf` → WebSite, `breadcrumb`,
  `primaryImageOfPage`, `datePublished`
- Skip `SearchAction` unless the site has other reasons to want it — it no longer renders.

### BreadcrumbList
- Required: `itemListElement` with `position`, `name`, `item` (absolute URL)
- Must mirror the visible breadcrumb trail and the actual URL hierarchy.

### FAQPage / QAPage
- `FAQPage` — valid, no Google display. Fine to keep, don't build a strategy on it.
- `QAPage` — different type, single user question with multiple answers, still supported.
- Either way: never mark up Q&A the visitor cannot see on the page.

## Graph wiring with @id

Most audited pages have four correct-looking blocks that assert nothing about each other. Wiring
them into one graph is usually the single highest-value structured-data fix available, and it
costs no new content.

Convention: `@id` is the canonical URL plus a fragment. Fragments are arbitrary but must be
consistent sitewide.

```json
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "Organization",
      "@id": "https://example.com/#organization",
      "name": "Example Co",
      "url": "https://example.com/",
      "logo": {
        "@type": "ImageObject",
        "@id": "https://example.com/#logo",
        "url": "https://example.com/logo.png",
        "width": 512,
        "height": 512
      },
      "sameAs": [
        "https://www.wikidata.org/wiki/Q000000",
        "https://www.linkedin.com/company/example-co"
      ]
    },
    {
      "@type": "WebSite",
      "@id": "https://example.com/#website",
      "url": "https://example.com/",
      "name": "Example Co",
      "publisher": { "@id": "https://example.com/#organization" },
      "inLanguage": "en-US"
    },
    {
      "@type": "WebPage",
      "@id": "https://example.com/blog/post/#webpage",
      "url": "https://example.com/blog/post/",
      "name": "Post title",
      "isPartOf": { "@id": "https://example.com/#website" },
      "primaryImageOfPage": { "@id": "https://example.com/blog/post/#primaryimage" },
      "datePublished": "2026-03-14T09:00:00-07:00",
      "dateModified": "2026-08-02T11:30:00-07:00",
      "breadcrumb": { "@id": "https://example.com/blog/post/#breadcrumb" }
    },
    {
      "@type": "BlogPosting",
      "@id": "https://example.com/blog/post/#article",
      "isPartOf": { "@id": "https://example.com/blog/post/#webpage" },
      "mainEntityOfPage": { "@id": "https://example.com/blog/post/#webpage" },
      "headline": "Post title",
      "image": { "@id": "https://example.com/blog/post/#primaryimage" },
      "datePublished": "2026-03-14T09:00:00-07:00",
      "dateModified": "2026-08-02T11:30:00-07:00",
      "author": { "@id": "https://example.com/#/schema/person/jane-doe" },
      "publisher": { "@id": "https://example.com/#organization" },
      "inLanguage": "en-US"
    },
    {
      "@type": "Person",
      "@id": "https://example.com/#/schema/person/jane-doe",
      "name": "Jane Doe",
      "url": "https://example.com/authors/jane-doe/",
      "jobTitle": "Principal Engineer",
      "sameAs": ["https://www.linkedin.com/in/janedoe"]
    },
    {
      "@type": "ImageObject",
      "@id": "https://example.com/blog/post/#primaryimage",
      "url": "https://example.com/img/post-hero.jpg",
      "width": 1200,
      "height": 675,
      "caption": "Descriptive caption"
    },
    {
      "@type": "BreadcrumbList",
      "@id": "https://example.com/blog/post/#breadcrumb",
      "itemListElement": [
        { "@type": "ListItem", "position": 1, "name": "Home", "item": "https://example.com/" },
        { "@type": "ListItem", "position": 2, "name": "Blog", "item": "https://example.com/blog/" },
        { "@type": "ListItem", "position": 3, "name": "Post title" }
      ]
    }
  ]
}
</script>
```

Notes on this pattern:
- One `<script>` with a `@graph` beats five separate scripts. Fewer places for a template to
  break, and the relationships are explicit.
- The final breadcrumb `ListItem` intentionally omits `item` — it is the current page.
- `Person` `@id` uses a path-style fragment so author identity is stable across every article
  they write. Stability is the whole point of `@id`.
- Every internal reference is `{ "@id": "..." }` — a pointer, not a duplicated object. Repeating
  the full Organization object in six places guarantees they drift apart.

## Silent killers

Things that look fine in review and produce nothing:

- **Trailing comma** before `}` or `]`. Invalid JSON, block discarded whole, no warning anywhere.
- **Smart quotes** from a CMS rich-text field replacing straight quotes.
- **Unrendered template placeholders** — `{{ post.title }}` shipped to production.
- **Wrong script type** — `text/javascript` instead of `application/ld+json`. Never parsed.
- **Relative URLs** in `@id`, `url`, `image`, `sameAs`. Must be absolute.
- **Case-wrong types** — `Blogposting`, `Localbusiness`, `Faqpage` are not schema.org types.
- **Escaped HTML entities** inside JSON string values, e.g. `&quot;` where a real quote belongs.
- **`@context` as `http://`** — use `https://schema.org`.
- **Dates without timezone** or in `MM/DD/YYYY`. Use ISO 8601.
- **`dateModified` earlier than `datePublished`**, or either in the future.
- **Multiple conflicting blocks** — two `Organization` entities with different names, usually
  one from a plugin and one hand-added. Whoever wins is unpredictable; assume the worst one does.
- **Client-side injection only.** Google renders JS; most LLM retrieval crawlers and social
  scrapers do not. Server-render structured data.
- **Copy-paste `@id` collisions** — every article on the site claiming
  `https://example.com/#article`. The graph collapses into one entity.
