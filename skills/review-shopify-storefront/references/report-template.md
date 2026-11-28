# Report template

Verdict first. The reader is the owner, who has one question: how exposed am I
and what do I decide. Headings below are the order; keep them even when a
section is one line.

```markdown
# <Store>: pricing and promo review, <yyyy-mm-dd>

Audited against theme `<id>` on <host> and Shopify Admin · Discounts.

**Changed during the audit:** nothing. (Or exactly what, on whose instruction,
how it was verified, and how to reverse it.)

**Method:** <endpoints read, carts built, pages rendered, Admin views opened,
flows read — with counts>. No order placed, nothing submitted for payment, no
Admin setting changed.

**Not checked:** <apps, flows, codes read only from a list view, variations not
opened>. Say which rows of the register are list-view only.

**Prompted by:** <the event, if there was one>.

## Verdict
Three to five sentences. The register size and how many were known. The
largest live exposure, by name. The answer to the prompting question.

## 1. <The prompting question>, answered
Where the thing came from, with the flow or page quoted, and whether the code
behind it exists. Measured, with a control.

## 2. The discount estate
Who created them. The ones that do not stop (INV-P1). The large uncapped ones
(INV-P2). The duplicates (INV-P7). The ones that are correctly scoped and are
NOT findings — say so, or the reader assumes you missed them.

## 3. Prices and plans, measured
Table from the product endpoints: one-time, sum of parts, subscribed, rate, plan
name. Note anything the repo records as pending that has already landed.

## 4. The stack, measured at the cart
The stacking table, baseline stated. Rows over the cap in bold.

## 5. Corrections to the written record, including this document's own
Every claim in the repo's ops docs the audit disproved, and every claim an
earlier revision of this report made that this revision retracts — with HOW the
method produced the error. A report that never corrected itself has not been
checked.

## 6. Findings
P1 wrong · P2 missing · P3 polish. Each: what, evidence (code name, page URL and
quoted copy, Admin field, flow name), consequence in revenue or trust, the
invariant it breaks.

## 7. Decisions for you, not defects
Numbered questions only the owner can answer. Intent is not something the audit
can read off a screen.

## 8. The guardrail
What would stop this recurring: a policy file with the invariants, and a check
that runs against a read-only Admin export rather than a hand-kept list. Name
the scope the Custom App needs (`read_discounts`).

## 9. Still open
Unaudited surfaces, named. Variations not read. Drafts not opened — a draft is
one toggle from live.

## 10. Admin worklist
| where | item | current | target |. Every row needs sign-off. Nothing was changed.

## 11. Verify after changes
Checkboxes a person can tick in Admin and at a cart. Always include: every code
named in a live email applies to a real cart.
```

Label every finding with website-audit-package's three states when the store is
mid-project — live, fixed in source awaiting publish, open — and get the state
from Admin and the tracker, not from the rendered page.
