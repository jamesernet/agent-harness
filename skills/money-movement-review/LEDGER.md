# Ledger & Reconciliation

Rule set for trustworthy money records. Loaded by
[money-movement-review](SKILL.md); read it whenever ledgers, balances,
wallets, payouts, statements, or reconciliation jobs are in the code under review.

Two uses: design rules for new
ledger work, and a review procedure for existing systems. Findings ranked by
severity with evidence.

## Rules

### Double-entry
- Every movement is a balanced transaction: debits equal credits, per
  transaction, enforced at write time — not checked later by a job.
- No orphan postings. A posting exists only inside a transaction; a
  transaction with one leg is a bug the database should reject.
- Accounts have a type (asset/liability/income/expense/equity or your
  domain's equivalent) and exactly one currency. Cross-currency moves are
  two transactions joined by an FX event (see [MONEY.md](MONEY.md)), never one
  posting with an implicit rate.

### Immutability
- Append-only. Corrections are reversing entries plus a new entry — never
  UPDATE, never DELETE. If the schema permits UPDATE on postings, that's
  finding #1 regardless of whether the code currently does it.
- Every entry carries: timestamp, actor/source (which system or human),
  idempotency key, and a reference to the business event that caused it.

### Balances
- Balances are derived from postings (sum, or materialized with a rebuild
  path). A balance column mutated in place with no way to reproduce it from
  postings is not a ledger — it's a rumor.
- Posting is idempotent: replaying the same business event produces no
  double-count. Unique constraint on (source, idempotency key).
- Pending vs posted are distinct states with distinct balance views
  (available vs actual). Value dates and timezones are explicit; "the day"
  is defined once (usually UTC or the settlement partner's cutoff).

## Reconciliation
- Internal ledger ↔ external truth (PSP reports, bank statements,
  settlement files) on a schedule matching the money's velocity.
- Match on the external party's id + amount + currency; every internal
  entry must be matchable (see the reconciliation hooks in [SKILL.md](SKILL.md)).
- Breaks (unmatched items) go to a suspense account with an aging clock and
  an owner — a break older than N days pages a human. Suspense trending to
  zero is the health metric.
- Fees, FX residue, and rounding differences get their own accounts, so
  "small unexplained differences" never get absorbed silently.

## Controls
- Trial balance job: total debits equal total credits across the whole
  ledger, on a schedule, alerting on any imbalance — this catches bugs
  nothing else will.
- Statement generation reads only from the ledger, never from application
  state, so statements and balances cannot disagree.

## Review procedure
1. Schema first: can postings be updated or deleted? Are single-leg writes
   possible? Is there a balance column, and can it be rebuilt from postings?
2. Trace one business event (a charge, a payout) to its postings: balanced,
   idempotent, referenced back to the event?
3. Trace one external settlement line to its internal match. Ask to see the
   current suspense/breaks list and its age distribution.
4. Run (or ask for) a trial balance. If nobody can produce one, that is the
   finding.

## Test checklist
- Replay the same event twice: one set of postings.
- Post a deliberately unbalanced transaction: rejected at write time.
- Rebuild a balance from postings: matches the materialized value.
- FX transaction: both legs balanced in their own currencies; residue lands
  in the designated account.
- Reconciliation with a mutated external file: break detected, aged, surfaced.

## Related
- [MONEY.md](MONEY.md) · [SKILL.md](SKILL.md) (the review procedure)
