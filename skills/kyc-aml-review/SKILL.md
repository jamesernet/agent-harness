---
name: kyc-aml-review
description: Review a KYC/AML program's technical implementation — identity verification, sanctions/PEP screening, risk rating, transaction monitoring, case management, SAR workflow. Use when building or reviewing onboarding, compliance screening, or monitoring systems for a fintech.
---

# KYC / AML Review

Reviews the *engineering* of a compliance program — whether the systems do
what the compliance policy claims. The policy itself, jurisdiction
selection, and regulator relationships belong to compliance counsel; flag
gaps, don't play lawyer. Regimes differ (FinCEN/BSA, EU AMLD, FCA…) —
verify jurisdiction-specific thresholds and timelines rather than assuming.

## The pipeline, and what to check at each stage

### 1. Identity verification (CIP/IDV)
- Document + liveness via a vendor; what are the pass/fail/manual-review
  thresholds, and who tunes them? Failed-verification retry limits?
- Verification state is a proper state machine (unverified → pending →
  verified / rejected / manual-review), and product features are gated on
  it — check for endpoints that work pre-verification but shouldn't.
- Identity documents are sensitive PII: retention, encryption, and access
  audit per data-privacy-review.

### 2. Screening (sanctions / PEP / adverse media)
- At onboarding **and** ongoing — lists change; customers get re-screened
  on list updates, not just at signup. Screening only at signup is the
  most common real finding.
- Fuzzy matching produces false positives by design: there is an alert
  queue, an SLA, a documented disposition for every alert, and an audit
  trail on who cleared what and why.
- No customer-visible signal that they matched a list. Screening state
  never leaks into API responses, UI, or error messages.

### 3. Risk rating
- Each customer gets a risk score from documented factors (geography,
  product usage, volume, entity type), recomputed on relevant change, and
  the score *drives something* — enhanced due diligence, limits, review
  cadence. A score nothing reads is decoration.

### 4. Transaction monitoring
- Rules (velocity, structuring-under-thresholds, rapid in-out, dormant
  account awakening…) run on complete data — verify the pipeline actually
  sees every transaction type, including internal transfers and refunds.
- Alerts land in case management with ownership, SLA, aging, and
  disposition. Measure alert quality (hit rate); an unreviewed backlog is
  the program failing in slow motion.
- Rule changes are versioned with who/when/why — regulators ask.

### 5. Reporting (SAR/STR) workflow
- Case → decision → filing has a tracked clock (e.g., 30 days from
  detection under BSA — verify per jurisdiction).
- **No tipping off**: nothing user-visible changes because a SAR exists;
  SAR data is segregated with tight access and its own audit log.
- Record retention (typically 5 years) covers the case file, the
  underlying data, and the audit trail.

## Review procedure
Trace two journeys end-to-end: (1) one customer from signup through
verification, screening, and risk rating; (2) one alert from rule-fire
through disposition (or SAR). The gaps show up in the traces, not the docs.

## Red flags — instant findings
- Screening at signup only; no re-screening on list updates.
- Manual overrides with no audit trail.
- Monitoring pipeline that misses a transaction type.
- Compliance state (screening hits, SAR existence) visible to users or
  ordinary support staff.

## Related
- [data-privacy-review](../data-privacy-review/) · [money-movement-review](../money-movement-review/) · [tech-due-diligence](../tech-due-diligence/)
