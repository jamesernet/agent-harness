---
name: pci-dss-scoping
description: Scope PCI DSS for a system — map cardholder-data flows, shrink the CDE, choose the right SAQ, plan segmentation. Use when a product touches card payments and someone asks what PCI applies, how to reduce scope, or which SAQ to fill.
---

# PCI DSS Scoping

The goal is never "pass PCI" — it's **shrink the cardholder-data
environment (CDE) until compliance is small**, then evidence it. Most
startups should be architecting to never touch a PAN at all.

## Procedure

### 1. Map where card data flows
Trace the PAN (and expiry, CVV) through capture → transit → processing →
storage → display. Every system it touches, plus every system with an
unrestricted network path to those, is in scope. The map is the scoping
document; keep it current.

### 2. Architect scope down (in order of preference)
1. **Never touch**: PSP-hosted checkout page or hosted fields/iframes —
   card data goes browser→PSP directly; you handle only tokens. → SAQ A
   (or A-EP if your page's scripts can affect the payment form).
2. **Tokenize at the edge** if you must accept PAN server-side, exchange
   for a token immediately, store only tokens.
3. **Store PAN yourself** — almost never justified for a startup; if a
   client insists, make them defend it against the cost of SAQ D + audits.

### 3. Absolute rules regardless of scope
- Never store CVV/CVC or full track data. Not encrypted, not briefly,
  never — post-authorization storage is prohibited outright.
- PAN is masked on display (first 6 / last 4 max) and never appears in
  logs, URLs, analytics, error trackers, or support tickets. Grep for it —
  16-digit sequences in logs are the most common real finding.
- Segmentation: the CDE is network-isolated from everything else, and the
  isolation is *tested*, or the whole flat network is in scope.

### 4. Choose the validation level
- SAQ A — fully outsourced capture (hosted page/iframe), no card data
  touches your systems.
- SAQ A-EP — e-commerce where your code can influence the payment page.
- SAQ D — you store/process/transmit card data. Big. Avoid.
- Level 1 (assessor-audited ROC) at high transaction volumes — confirm
  current thresholds with the acquirer; they set the requirement.
Confirm the exact SAQ with the acquirer/PSP — they decide, not us. Verify
current PCI DSS version requirements (v4.x) rather than relying on memory;
requirements like script integrity monitoring on payment pages tightened
in v4.

### 5. Evidence as you go
Keep the flow map, segmentation test results, quarterly ASV scan reports,
and the token-only schema proof in one place. Diligence and assessors ask
for the same artifacts (see tech-due-diligence §5).

## Red flags — instant findings
- CVV column in any schema, ever.
- PAN accepted by your API "just to forward it" without immediate
  tokenization and a scope acknowledgment.
- Payment page pulling third-party scripts with no integrity controls.
- "We're SAQ A" while server-side code handles raw PANs.

## Related
- [money-movement-review](../money-movement-review/) · [threat-model](../threat-model/) · [tech-due-diligence](../tech-due-diligence/)
