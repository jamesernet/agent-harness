---
name: shopify-storefront-review
description: Review a Shopify storefront's money and offer logic — every live discount, automatic discount, selling-plan rate, partner and affiliate code, bundle price and the email flows that publish them — against what the pages, emails and docs claim. Builds the offer register the store usually lacks, measures prices and stacking at a real cart, finds dead codes in live emails, and reports decisions separately from defects. Use when a Shopify, Recharge, Klaviyo, GoAffPro or similar store needs a pricing, promo code, discount, subscription, bundle, partner-code, abandoned-cart, welcome-offer, cart-drawer or checkout-path review, when a customer received a discount nobody can account for, when prices or percentages on pages disagree, or before changing any rate. Theme copy is in scope wherever it states a price or rate; crawlability, structured data and performance are not — hand those to sitescan, metadata-audit and web-perf.
effort: high
---

# Shopify Storefront Review

Read-only. The store is a client's business and its Admin is production: no
order is placed, nothing is submitted for payment, no discount, flow, product or
setting is created, edited or disabled. Changes are a worklist the owner signs
off, applied by a person, verified afterwards.

The output is a report in the shape of [report-template.md](references/report-template.md)
and, underneath it, the **offer register** described in
[register-and-invariants.md](references/register-and-invariants.md). The
register is the deliverable that makes everything else checkable, and the store
almost never has one: the case this skill is distilled from documented four
discounts and had twenty-seven.

## What this is not

The machine layer and speed are measured by other tools and must not be
re-measured here: `sitescan` for crawlability, structured data, contrast and
alt text on commerce sites; `metadata-audit` for the head and robots layer;
`web-perf` or a Lighthouse snapshot for load times. Quote their numbers, with
their dates, in one section of the report. Theme hygiene (Liquid, sections,
settings) is in scope only where a surface states a price or rate.

## Inputs, in order of authority

1. **Shopify Admin · Discounts** — the list, then every detail page. Or a
   read-only `discountNodes` export from a Custom App with `read_discounts`.
   This is the only source that can enumerate what exists.
2. **The product endpoints** — `/products/<handle>.js` for every product and
   bundle: one-time price, `compare_at_price`, and the selling-plan allocations
   a subscription app (Recharge, Shopify Subscriptions, Skio…) attaches. Run
   `scripts/storefront-prices.sh <host> <handle>…`; it derives the rate from the
   two prices and prints the customer-facing plan name beside it.
3. **Real carts** — `/cart/add.js` with a `/discount/<code>` cookie, read back
   from `/cart.js`. The only way to learn what a path actually charges.
4. **Rendered pages** — the PDPs, the bundle page, the collection, the home page,
   any quiz or routine builder, the footer and signup forms, the cart drawer.
   Every surface that states a price, a percentage, a saving or a condition.
5. **The email and automation platform** — Klaviyo or equivalent: every live
   flow, its trigger, its emails, every code or offer its copy names, its
   dedupe setting, and each A/B variation. Needs a person to log in; ask.
6. **Apps that issue or honour offers** — affiliate (GoAffPro, UpPromote,
   Impact), loyalty (Yotpo), subscriptions (Recharge). Each is a source of
   discounts the Admin list may not show.
7. **The repo's own docs** — runbooks, action lists, specs. These are what the
   register is checked against; they are never its source.

State in the report which of these were read, with counts, and which rows of
the register came from a list view only.

## Method rules

These are the mistakes the source audit made and then had to retract. They go in
the report's corrections section when broken.

- **Fetch a control before reporting a null.** Before saying a code does not
  exist or does not apply, apply a code you know works, in the same run, to the
  same cart shape. A code scoped to subscriptions, or needing three items, is
  indistinguishable from a code that does not exist when probed against a
  one-time single-item cart.
- **The storefront probe measures codes you know about; it cannot enumerate.**
  Only Admin or the discount export says what exists. A report of "three live
  codes" from probing a list copied out of the repo was off by a factor of
  eight.
- **A 429 reads as "no discount applied."** Shopify rate-limits `/discount/`
  and answers with an empty body. Re-run the control after any batch; if the
  control fails, the batch is void.
- **`/discount/<nonexistent>` answers 302 with no error.** Silence is not
  success. Read the cart back.
- **Two codes never combine.** The second silently replaces the first. Report
  which code survives, not a stack.
- **Measure, do not compute.** Build the path as a cart and read the total.
  Apply the baseline arithmetic afterwards, and state the baseline.
- **Name what was not checked.** Drafts not opened, variations not read, apps
  not logged into. A draft is one toggle from live.

## Procedure

### 1. Scope and the prompting question

What triggered the review (a customer with an unexplained 15%, a cap nobody
can confirm, a replatform). That question gets section 1 of the report and is
answered first, with the mechanism quoted.

Agree the **cap** and its **baseline** with the owner before measuring: a 35%
cap against the sum of the parts and against the bundle's own list price give
different breach lists. If nobody can say, measure against both and put the
choice in "Decisions".

### 2. Build the register

From Admin, one row per discount with every column in the reference, including
`created by`: apps and AI connector apps are actors, and five actors with no
review is itself a finding. Mark the correctly scoped large codes (a 100% code
restricted to named customers) as not-findings explicitly.

### 3. Measure prices and plans

`scripts/storefront-prices.sh` over every product and bundle. Record one-time,
sum of parts, subscribed, derived rate, plan name. Note what the repo records as
pending that has already landed, and what it records as done that has not.

### 4. Measure the stack

For each reachable path in the stacking table, build the cart, apply the code,
read the total, compute "off baseline". Include the paths nobody put on the list
of codes to test — the ones with "all recurring payments" scope are routinely
the largest exposure and routinely missing from every list.

### 5. Read the flows

Every live flow: trigger, emails, subject and preview text, the code each
message names, dedupe setting, variations. For each named code: **does it exist
in the register, and does it apply to a real cart?** Two flows with different
triggers can both fire for one shopper; say whether anything dedupes them.
Record the flow's own numbers (recipients, opens, clicks, orders). Where two
welcome flows are live on two lists, check whether one signup can land on both
lists — the list membership, not just the per-email "skip recently emailed"
setting — and whether either flow matches the written spec's trigger.

### 6. Check every claim

Walk the surfaces: PDP price chip against plan terms; collection cards; the
quiz's question against its answer; the footer promise against a code and a
flow that exist; the partner page's conditions against the code's scope; every
sentence in the ops docs against Admin. Each disagreement is a finding with the
quoted copy and the configured value side by side.

### 7. Cart and checkout path

Add-to-cart opens a drawer or loads `/cart`; whether choosing a subscription
option actually produces `selling_plan_allocation` lines; what the default
selection is; where accelerated checkout buttons sit. If order data is
available, the share of orders through accelerated checkout is the fingerprint
of a broken primary buy path. After a replatform, replay the legacy URL list
and record what every retired URL does today.

### 8. Write the report

Template order, verdict first. Findings cite the invariant they break.
Decisions the owner must make are a separate section from defects: whether a
100% code with 72 redemptions is a sampling programme or a leak is not something
a screen can tell you. Keep every correction, including to this report's own
earlier revision, with how the method produced the error.

### 9. Propose the guardrail

A policy file carrying the invariants, and a check that runs against a
read-only Admin export rather than a hand-kept list — the export is the half
that matters, because a hand-kept register drifts exactly the way the docs did.
Name the Custom App scope needed. Do not build it inside the review.

## Red flags, instant findings

- A discount with "all recurring payments" scope and no usage limit.
- A high-value code open to all customers with no cap and no end date.
- A code named in a live email that is not in the register.
- The same percentage available through several unrelated codes.
- A welcome offer in the footer copy with no flow or code behind it.
- Two live welcome flows on two lists.
- A rate written into theme copy rather than derived from the allocation.
- A spec that says "limit to one use per customer" and a discount without it.

## Related

- [website-audit-package](../website-audit-package/) — three-state labels and the package this report lands in
- [product-ux-review](../product-ux-review/) — the cart drawer and checkout interactions themselves
- [money-movement-review](../money-movement-review/) — where the store's own payment or ledger code is in scope
- [data-privacy-review](../data-privacy-review/) — flows, pixels and consent on the same pages
