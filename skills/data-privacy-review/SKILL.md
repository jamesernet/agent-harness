---
name: data-privacy-review
description: Review how a system collects, stores, shares, and deletes personal data — PII inventory, retention, deletion paths, DSAR readiness, residency, processors. Use when code or schemas touch user personal data, emails, analytics or tracking pixels (GA4, GTM, Meta pixel), cookie banners and consent (Consent Mode), third-party data sharing, AI vendors receiving user data, or when GDPR/CCPA questions come up.
---

# Data Privacy Review

How I audit a system's handling of personal data. Output: a findings list
ranked by severity, plus the PII inventory if one doesn't exist — the
inventory is usually the deliverable that unlocks everything else.

## Procedure

### 1. Inventory
For each category of personal data: what is collected, where it lives
(every store: DB, warehouse, logs, analytics, error tracker, backups,
spreadsheets), why it's needed, and who can access it. If the honest
answer to "why" is "we might need it," that's collection without purpose —
a finding.

### 2. Minimization and purpose
- Collect the minimum for the stated purpose; derived/enriched data counts.
- Purpose creep check: is data collected for X being used for Y
  (especially marketing, analytics, or model training)?
- Special categories (health, biometrics, precise location, children's
  data) get flagged separately — higher bar everywhere.

### 3. Retention and deletion — the part that's always broken
- Every data category has a retention period and an *implemented* deletion
  path. A policy document without a cron job is a finding.
- Deletion must reach the long tail: replicas, warehouse, logs, analytics,
  error trackers, search indexes, caches, backups (document the backup
  expiry story — "deleted on restore" needs an actual mechanism), and any
  third party the data was shared with.
- Anonymization claims get scrutiny: if it can be re-linked, it's
  pseudonymized, and it's still personal data.

### 4. DSAR readiness
Can the team, today, for one user: export everything (access/portability),
correct it, and delete it — within the statutory window (30 days GDPR, 45
CCPA)? Walk the actual mechanism, not the intention. Verify the requester's
identity before disclosing anything.

### 5. Processors and transfers
- Every third party receiving personal data: DPA in place, purpose bound,
  deletion propagated. This includes analytics, support tooling, and **AI
  vendors — prompts containing user data are a data transfer**.
- Cross-border transfers have a lawful mechanism (SCCs/adequacy);
  residency requirements (data must stay in region X) are architecture
  constraints, so surface them early.

### 6. Security posture (privacy-relevant slice)
Encryption in transit and at rest, access on least privilege with audit
logs on PII access, and a breach-notification path with owners and clocks
(72h GDPR). Deeper security review belongs to threat-model.

## Red flags — instant findings
- PII in application logs or error trackers (emails, tokens, addresses).
- User data in prompts to third-party AI services with no DPA/opt-out.
- "Soft delete" as the only delete.
- Analytics/tracking firing before consent where consent is required.
- One database role that every service and employee shares.

## Related
- [threat-model](../threat-model/) · [kyc-aml-review](../kyc-aml-review/) (identity data overlaps) · [tech-due-diligence](../tech-due-diligence/) §5
