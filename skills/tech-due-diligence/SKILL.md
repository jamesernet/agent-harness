---
name: tech-due-diligence
description: Run a technical due-diligence pass on a codebase/company — architecture, team, risk, security/compliance posture, scalability, roadmap credibility. Use for investor/M&A diligence or pre-engagement situation reviews.
effort: xhigh
---

# Technical Due Diligence

My repeatable diligence pass. Three flavors share one skeleton but differ in
depth, audience, and tone — state which one applies before starting:

- **Investor diligence** — pre-investment. Audience: partners. Emphasis:
  risk, defensibility, team, whether the tech supports the thesis.
- **M&A** — pre-acquisition. Audience: acquirer eng leadership. Emphasis:
  integration cost, key-person risk, liabilities.
- **Situation review** — pre-engagement or new-CTO onboarding. Audience:
  the founder. Emphasis: what to fix first, what to deliberately leave alone.

Playbook templates for scoping and deliverables live in the jamesernet.com
repo under `docs/knowledge/playbooks/` (fractional-cto-engagement,
engagement-products).

## 1. Scope and inputs

Agree upfront: repos in scope, read-only infra access, docs, interviewees,
timebox. Standard request list:
- all repo access (including infra/IaC), CI/CD config, dependency manifests
- architecture docs and ADRs — their absence is itself a finding
- cloud console read access or cost exports
- incident history, on-call setup, monitoring dashboards
- security/compliance artifacts: pen tests, SOC 2 / PCI status, prior audits
- org chart, tenure, contractor-vs-employee split

## 2. Architecture
- Draw the system as it actually is — from code and infra, not the diagram
  they hand you. Diff the two; the gap is informative.
- Identify the irreversible decisions already made (datastore, multi-tenancy
  model, event backbone, vendor lock-in) and whether they were made
  deliberately or by drift.
- Single points of failure — technical and human.
- Debt: distinguish deliberate scaffolding from accidental complexity.
  Understand before you rebuild — debt is only a finding if it blocks the
  roadmap or compounds cost.

## 3. Codebase health
- Tests: existence, honesty (do they assert anything real), CI gating,
  time-to-green.
- Delivery mechanics: deploy frequency, rollback story, commit-to-prod time.
- Observability: could they diagnose an incident from what's captured today?
- Navigability: can a new engineer — or an agent — find their way? Docs,
  naming, module boundaries.
- Sample deeply rather than skim widely: pick 2–3 core flows and read them
  end-to-end.

## 4. Team and delivery
- Key-person risk: what exists only in someone's head? Bus factor per
  critical system.
- Delivery cadence: shipped-vs-planned over the last 2–3 quarters, taken
  from tracker history, not testimony.
- Hiring plan realism against the roadmap.

## 5. Security and compliance
- Run [threat-model](../threat-model/) on the highest-value flow.
- Run [pci-dss-scoping](../pci-dss-scoping/), [data-privacy-review](../data-privacy-review/),
  and [kyc-aml-review](../kyc-aml-review/) as the domain requires; use the
  built-in `/security-review` for the code-level pass.
- Check secrets handling, access control, dependency vulnerabilities,
  offboarding hygiene.

## 6. Scalability and cost
- Where does it break first — load, data volume, tenant count — and what is
  the cheapest next fix?
- Infra unit economics: cost per user/transaction and its trend. Anything
  scaling superlinearly is a finding.

## 7. Roadmap credibility
- Take the stated roadmap, timeline, and budget. Test them against team
  size, observed delivery cadence, and the debt found above. Say plainly
  whether the plan is credible — and if not, what would make it credible.

## Output
1. **Findings memo** — roughly a page per major area; lead with the answer.
2. **Risk register** — ranked: risk, severity (impact × likelihood),
   evidence, mitigation, cost/effort to mitigate.
3. **30/60/90 recommendation** (situation reviews only) — what to fix first
   and what to deliberately not fix.

Rules for findings:
- Every finding cites evidence — a file, a metric, an interview. No vibes.
- Severity is judged from the buyer's or founder's perspective, not
  engineering aesthetics.
- Distinguish "expensive to reverse" from "not how I'd do it." Only the
  former belongs in the top tier.

## Related
- [threat-model](../threat-model/) · [pci-dss-scoping](../pci-dss-scoping/) · [data-privacy-review](../data-privacy-review/) · [kyc-aml-review](../kyc-aml-review/) · [improve-codebase-architecture](../improve-codebase-architecture/) (post-diligence deepening)
