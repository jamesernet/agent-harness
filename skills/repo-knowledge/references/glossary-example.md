# Worked business glossary example

This fictional subscription business illustrates writing choices, not business
facts to copy. Its source policies, names and dates are synthetic. In a real
library, use inspected evidence, actual authorship and the repo's chosen paths.
No aliases field, new type taxonomy or metric runtime is required.

## Keep business and implementation meanings distinct

Suppose the inspected billing policy defines a **Customer** as an organization
with a subscription contract, while the authentication schema defines a **User**
as a person with a login. Create `business/customer.md` and `platform/user.md`;
link their relationship. One customer can have many users, and a prospective user
might have no customer relationship. Document those cardinalities only if the
actual policy or code supports them.

If sales calls a customer a “client,” record that as an evidenced alias. If
`account` means a billing customer in one subsystem and a login in another,
qualify it in prose and links rather than silently merging the concepts.

An example `business/customer.md`:

```markdown
---
type: Concept
title: Customer
description: An organization holding a subscription contract in the billing context.
tags: [business, billing]
generated: { by: process:example-template, at: "2026-11-20T00:00:00Z" }
status: draft
sources:
  - id: billing-policy
    resource: https://example.com/policies/subscriptions
    title: Fictional subscription policy
  - id: identity-contract
    resource: https://example.com/contracts/identity
    title: Fictional identity contract
---

# Customer

In the billing context, a **Customer** is an organization holding a subscription
contract. Sales also uses **Client** for this relationship.[^billing-policy]

A [User](../platform/user.md) identifies a person with access.[^identity-contract]
The billing policy permits multiple users per customer.[^billing-policy]

[^billing-policy]: Fictional subscription policy, terminology and membership sections.
[^identity-contract]: Fictional identity contract, User definition.
```

The business definition and implementation definition have separate evidence.
Replace both synthetic sources with the inspected policy and schema; pin code
sources to the inspected revision. Use an explicit draft gap when a relationship
is unresolved.

The paired `platform/user.md` keeps the implementation meaning separate:

```markdown
---
type: Concept
title: User
description: A person represented by a login identity in the authentication context.
tags: [platform, identity]
generated: { by: process:example-template, at: "2026-11-20T00:00:00Z" }
status: draft
sources:
  - id: identity-contract
    resource: https://example.com/contracts/identity
    title: Fictional identity contract
---

# User

In authentication, a **User** identifies a person with access through a login
identity.[^identity-contract] Use [Customer](../business/customer.md) for the
billing term.

[^identity-contract]: Fictional identity contract, User definition.
```

## Define metrics through other terms

An example `metrics/active-customer-count.md` can lead with its definition:

```markdown
---
type: Metric
title: Active customer count
description: Distinct customers whose contract is active at the observation instant.
tags: [business, metric]
generated: { by: process:example-template, at: "2026-11-20T00:00:00Z" }
status: draft
sources:
  - id: reporting-policy
    resource: https://example.com/policies/customer-reporting
    title: Fictional reporting policy
---

# Active customer count

Active customer count(t) = count(distinct customer.id where contract is active at t).

The population is [Customers](../business/customer.md) with an active contract at
the observation instant t, in UTC. Unit: customers. This is a stock observed at t;
it does not count new customers acquired over a period.[^reporting-policy]

[^reporting-policy]: Fictional reporting policy, active-customer definition.
```

Link an existing canonical computation or runtime definition if the repo has one.
Keep calculations in that authority rather than inventing another implementation.
For a ratio, identify numerator and denominator concepts and the established
zero-denominator behavior; leave an undefined policy as a question.

## Make it discoverable

The bundle root links the Business, Platform and Metrics indexes. Each directory
index lists its own concepts with a short description. Contextual links connect
Customer, User and Active customer count, while directory indexes provide entry
paths. These are two uses of links; both help readers find the intended meaning.
