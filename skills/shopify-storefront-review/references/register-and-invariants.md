# The offer register, and the invariants it is checked against

The register is the deliverable that makes every other finding checkable. A
store without one cannot answer "where did this customer's discount come
from", and the answer "we have a few codes" is usually off by a multiple.

## Register columns

One row per discount, automatic discount, price rule, selling-plan rate,
partner or affiliate code, loyalty reward and bundle price. Fill from Admin or
the `discountNodes` export, never from the repo's own docs — the docs are what
the register is checked against.

| column | why it is there |
|---|---|
| name / code | the string a customer types or a flow emails |
| kind | code, automatic, selling plan, app-issued (name the app), bundle price |
| value | percentage or amount, and what it applies to (order, products, collections, shipping) |
| scope | one-time only · subscriptions limited to 1 recurring payment · **all recurring payments** · both |
| usage limit | total cap, or none |
| per-customer limit | one per customer, or none |
| customer eligibility | all, segments, named customers |
| requires selling plan | subscription-only products have no one-time price; carry the flag |
| start / end | end date, or none |
| combines with | product, order, shipping discounts; or nothing |
| uses · sales | redemptions and revenue to date |
| created by · when | staff name, app name, connector; apps and AI connectors count as actors |
| owner · campaign | who is accountable and what it is for; blank is a finding |
| published where | every page, email, form, popup or partner that states it |

## Invariants

Numbered so a report can cite them and a later check script can encode them.

- **INV-P1, critical.** No active discount has "all recurring payments" scope
  together with no usage limit. One redemption is a permanently discounted
  subscription.
- **INV-P2, critical.** No active discount above the agreed ceiling (default
  50%) lacks both a usage cap and a customer restriction. A 100% code
  restricted to a few named customers is fine; a 100% code open to everyone
  with dozens of redemptions is the largest number in the report.
- **INV-P3, high.** Every active discount appears in the register with an
  owner and a campaign.
- **INV-P4, high.** No reachable stacking path exceeds the agreed cap, measured
  against the agreed baseline. State the baseline; "35% off" means nothing until
  someone says off what (the parts, or the bundle's own list price).
- **INV-P5, medium.** Every rate displayed in theme copy or a plan name is
  within one point of the plan or discount that grants it. Truncation and
  rounding produce "save 4%" beside "5% discount" for the same rate.
- **INV-P6, critical.** Every discount code named in a live email, form, popup
  or partner page applies to a real cart. A dead code in an abandonment email is
  worse than an unplanned discount: it is an unplanned discount that does not
  work, sent to people who already hesitated once.
- **INV-P7, high.** No two live offers give the same value for the same
  situation unless that is a decision. Several unrelated codes at the same
  percentage is why nobody could say which one a customer had.
- **INV-P8, medium.** A first order has a reason to choose the path the store
  wants chosen. If the welcome code and the subscription both give 15%, a
  first-time buyer is indifferent, and the store has paid for nothing.
- **INV-P9, high.** Documented specs match configuration: a spec that says
  "tick one use per customer" and a discount with no limit is a finding on the
  configuration, and the doc is cited as the evidence of intent.

## Stacking table

Measure, do not compute. Build each path as a real cart and read the charged
total back; apply the baseline afterwards.

| path | charged | baseline | off baseline |
|---|---|---|---|
| single, subscribed | | one-time price | |
| single, one-time, welcome code | | one-time price | |
| single, subscribed, welcome code | | one-time price | note whether the code applied at all |
| single, subscribed, each partner code | | | |
| bundle, one-time | | sum of parts | |
| bundle, subscribed | | sum of parts | |
| bundle, one-time, each code | | sum of parts | |
| bundle, subscribed, each code | | sum of parts | |

Two codes never combine in a Shopify cart: the second silently replaces the
first, with no error. Do not report a "stack" of two codes; report which one
survives.
