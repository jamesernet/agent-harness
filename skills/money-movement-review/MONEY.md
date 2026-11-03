# Money Modeling

Rule set for how money is represented and computed. Loaded by
[money-movement-review](SKILL.md); read it whenever amounts, prices, fees,
balances, or currency conversion are in the code under review.

Use it two ways: as design rules
when writing new money-handling code, and as a review procedure when auditing
existing code. When reviewing, output findings ranked by severity with
file/line evidence.

## Rules

### Representation
- Never binary floats for money. Not in code, not in the DB, not in JSON.
  `0.1 + 0.2 !== 0.3` is a ledger break waiting to happen.
- Default: integer minor units (`amount_minor: 1050` = $10.50). Exact, fast, portable.
- Arbitrary-precision decimal only where sub-minor-unit precision genuinely
  exists: FX rates, unit prices, interest accrual, crypto. Convert to minor
  units at the ledger boundary, once.
- An amount without a currency is a bug. Money travels as `(amount, currency)`
  — one value object / struct / column pair. No bare numbers crossing
  function or API boundaries.

### Currency
- ISO 4217 codes. Store the code, never a symbol.
- Minor-unit exponent varies: JPY = 0, most = 2, BHD/KWD/OMR = 3. Never
  hardcode `/100` — look up the exponent per currency.
- Currency mismatch is an error. `USD + EUR` should be a type error or a
  thrown error, never silent addition or silent coercion.

### Rounding
- Pick one rounding mode per context and write it down. Half-even (banker's)
  for accumulation/aggregation; half-up is commonly required for consumer
  display and some tax rules — check the jurisdiction, don't assume.
- Round once, at a defined point — usually where a computed decimal becomes a
  stored minor-unit amount. Intermediate computation keeps full precision.
- Rounding differences land somewhere explicit (a rounding/residual account),
  they never just vanish.

### Allocation
- Splitting an amount N ways: largest-remainder method. The sum of the parts
  must equal the whole — exactly, always. Assert it.
- Proportional splits: compute all parts, assign the remainder
  deterministically (largest fractional part, then a stable order). Document
  the tie-break; it will be asked about in an audit.

### FX
- A conversion is an event, not a formula. Record: base amount, quote amount,
  rate applied, rate source, timestamp, direction.
- Never derive the inverse as `1/rate` for accounting purposes; store the
  rate actually applied in the direction it was applied.
- Spread/margin is its own recorded component, not smeared silently into the rate.

### Boundaries
- JSON: integer minor units plus currency (`{"amount_minor": 1050,
  "currency": "USD"}`) or string decimal. Never JSON number floats.
- DB: `BIGINT` minor units or `NUMERIC(p,s)`. Never `FLOAT`/`DOUBLE`/`REAL`.
- APIs: state the unit convention explicitly in the contract. Stripe-style
  minor units is the safe default.
- Display formatting is presentation-only. Locale-formatted strings never
  feed back into computation.

## Review procedure

1. Grep for smells: `float`, `double`, `parseFloat`, `Number(`, `toFixed`,
   `/ 100`, `* 100`, `Math.round` near money-ish identifiers (amount, price,
   fee, balance, total).
2. Scan the schema: float/real columns holding amounts; amount columns with
   no currency column beside them.
3. Trace one amount end-to-end (input → compute → store → display → export)
   and note every conversion and rounding point. There should be few, and
   each should be deliberate.
4. Check aggregation paths (totals, fees, splits, refunds) for drift: does
   the sum of the parts equal the whole?
5. Check FX paths for rate capture, direction, and timestamping.

## Test checklist
- Rounding edges: `.005` cases in the chosen mode, verified against a
  hand-computed table.
- Allocation: split 100 by 3; split 1 by 3; parts sum to the original.
- A zero-decimal (JPY) and a three-decimal (BHD) currency through every path.
- Currency mismatch raises.
- Max plausible amounts: 64-bit ints cover minor units comfortably; 32-bit
  does not. Prove no overflow.
- Serialization round-trip: value out equals value in, exactly.

## Related
- [SKILL.md](SKILL.md) (the review procedure) · [LEDGER.md](LEDGER.md)
