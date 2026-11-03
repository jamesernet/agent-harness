---
name: threat-model
description: Threat-model a system or flow — data-flow diagram, trust boundaries, STRIDE enumeration, ranked mitigations. Use when designing or reviewing auth, payment, webhook, file-upload, or admin flows, handling untrusted input, or when a security review of an architecture is needed.
---

# Threat Model

A lightweight, repeatable pass — one flow, one sitting, a ranked threat
table out the other end. Not a compliance artifact; a working document that
feeds the risk register. Run it on the highest-value flow first (in fintech:
money movement, auth, webhooks, admin).

## Procedure

### 1. Scope one flow
Name the flow, its entry points, and what an attacker gains by breaking it
(money, data, account takeover, reputation). One flow per pass — "threat
model the whole system" produces a document nobody reads.

### 2. Draw the data-flow diagram
Processes, data stores, external entities, and the data moving between
them. Mark every **trust boundary**: internet↔service, service↔service
with different privileges, user↔admin, us↔PSP/vendor, code↔untrusted
input (uploads, webhooks, LLM output). Boundaries are where threats live.

Draw it as a Mermaid `flowchart`, one `subgraph` per trust zone. The artifact
lands on the tracker, where Mermaid renders natively, and it stays text — so
it diffs, and the next pass edits it instead of redrawing it. A crossing you
cannot place in a subgraph is a boundary you have not named yet.

```mermaid
flowchart LR
  subgraph untrusted[Untrusted — internet]
    U[Cardholder]
    PSP[[PSP webhook]]
  end
  subgraph edge[DMZ — public API]
    API[checkout-api]
  end
  subgraph core[Trusted — internal]
    WORKER[settlement-worker]
    LEDGER[(ledger)]
  end
  U -->|card details| API
  PSP -->|signed event| API
  API -->|authorized amount| LEDGER
  WORKER --> LEDGER
```

Keep it to roughly fifteen nodes — Mermaid's layout is not controllable and
degrades past that, which is the same scope cap step 1 already sets. Nothing
in a terminal renders Mermaid, so an agent cannot see its own syntax errors:
stay on `flowchart`, `stateDiagram-v2` and `sequenceDiagram`, confirm the
diagram rendered before treating the pass as finished, and leave anything
that is not graph-shaped in prose rather than forcing it into a diagram.

### 3. Enumerate with STRIDE, per boundary crossing
- **S**poofing — can the caller be someone else? (auth on every crossing,
  webhook signatures, internal service auth)
- **T**ampering — can data be modified in transit or at rest? (TLS,
  integrity checks, signed payloads, append-only stores)
- **R**epudiation — can an actor deny having done it? (audit logs with
  actor, timestamp, and integrity; especially admin and money actions)
- **I**nformation disclosure — what leaks? (errors, logs, timing, IDs;
  PII/PAN in logs is the classic — see data-privacy-review, pci-dss-scoping)
- **D**enial of service — what's the cheapest way to take it down or run
  up its bill? (rate limits, quotas, queue backpressure, cost caps)
- **E**levation of privilege — can a user reach admin, or a service exceed
  its role? (authz on every object access — IDOR is still the most common
  real-world finding — least-privilege service credentials)

### 4. Rank and mitigate
Score each threat: likelihood × impact, judged from attacker economics
(what it's worth to them vs what it costs them). For each: existing
mitigation, proposed mitigation with effort, or explicit acceptance.
Unmitigated-and-unaccepted is not an allowed state.

### 5. Output
A table — threat, boundary, STRIDE class, score, mitigation, owner, status
— committed next to the architecture docs, and the top items copied into
the engagement risk register. Revisit when the flow changes shape, not on
a calendar.

## Red flags — instant findings
- Webhook or callback endpoints with no signature verification (the
  boundary everyone forgets — see money-movement-review).
- Authorization checked at the route but not at the object (IDOR).
- Admin actions with no audit trail.
- Secrets in code, config files in git, or logs.
- Internal services that trust each other because "it's inside the VPC."

## Related
- [money-movement-review](../money-movement-review/) · [data-privacy-review](../data-privacy-review/) · [pci-dss-scoping](../pci-dss-scoping/) · [tech-due-diligence](../tech-due-diligence/) §5
