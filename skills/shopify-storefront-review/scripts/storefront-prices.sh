#!/usr/bin/env bash
set -euo pipefail

# Read what the storefront actually charges, from the same endpoint every theme
# surface reads: /products/<handle>.js, which carries each variant's price and
# the selling-plan allocations a subscription app attaches to it.
#
#   storefront-prices.sh <host> <handle> [handle...]
#   storefront-prices.sh --json <host> <handle> [handle...]
#
# Public, read-only GETs. Prices are in minor units in the API and printed in
# major units here; the rate is derived from the two prices, never read from a
# plan name — plan names round, truncate and lie.
#
# A missing allocation is printed as "-" and is a fact to report, not an error:
# a product with no selling plan cannot be subscribed to, whatever the page says.
#
# Rate limits: on /discount/ the source audit saw Shopify answer a burst with
# HTTP 429 and an empty body, which a careless reader turned into "no discount"
# and then into a false finding. The same shape is assumed here for the product
# endpoint: this script stops on the first 429 and says so; it never retries
# silently and never reads an empty body as "no plans".

json=0
if [[ "${1:-}" == "--json" ]]; then
  json=1
  shift
fi
[[ "$#" -ge 2 ]] || {
  echo "usage: storefront-prices.sh [--json] <host> <handle> [handle...]" >&2
  exit 2
}
host="$1"
shift
[[ "$#" -gt 0 ]] || {
  echo "usage: storefront-prices.sh [--json] <host> <handle> [handle...]" >&2
  exit 2
}
host="${host#https://}"
host="${host#http://}"
host="${host%/}"
command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required" >&2
  exit 1
}

rows='[]'
for handle in "$@"; do
  url="https://$host/products/$handle.js"
  body="$(mktemp)"
  code="$(curl -sS --max-time 20 -o "$body" -w '%{http_code}' -A 'storefront-prices (read-only audit)' "$url" || echo 000)"
  if [[ "$code" == "429" ]]; then
    echo "error: HTTP 429 on $url — rate limited. Stop, wait, re-run; do not read an empty body as 'no plans'." >&2
    rm -f "$body"
    exit 3
  fi
  if [[ "$code" != "200" ]]; then
    echo "warning: HTTP $code on $url — skipped (a 404 means the handle is wrong or the product is unpublished)" >&2
    rm -f "$body"
    continue
  fi
  row="$(jq -c --arg handle "$handle" '
    def money: (. / 100) | tostring;
    .variants[] | .price as $vp | {
      handle: $handle,
      variant: .title,
      variant_id: .id,
      one_time: ($vp | money),
      compare_at: (if .compare_at_price then (.compare_at_price | money) else null end),
      plans: [ .selling_plan_allocations[]? | {
        plan_id: .selling_plan_id,
        plan: .selling_plan_group_id,
        per_delivery: (if .per_delivery_price then (.per_delivery_price | money) else null end),
        rate_pct: (if .per_delivery_price and $vp > 0
                   then (((1 - (.per_delivery_price / $vp)) * 10000 | round) / 100)
                   else null end)
      } ]
    }' "$body" | jq -s '.')"
  # Plan names live in a separate block; join them in so the report can quote
  # the customer-facing name beside the derived rate.
  names="$(jq -c '[.selling_plan_groups[]?.selling_plans[]? | {id, name}]' "$body")"
  row="$(jq -c --argjson names "$names" 'map(.plans |= map(. as $p | $p + {plan_name: (($names | map(select(.id == $p.plan_id)) | .[0].name) // null)}))' <<<"$row")"
  rows="$(jq -c --argjson r "$row" '. + $r' <<<"$rows")"
  rm -f "$body"
done

if [[ "$json" -eq 1 ]]; then
  jq . <<<"$rows"
  exit 0
fi

printf '%-34s %-14s %10s %10s %10s %8s  %s\n' handle variant one_time compare_at subscribed rate plan
jq -r '.[] | . as $v |
  if ($v.plans | length) == 0 then
    [$v.handle, $v.variant, $v.one_time, ($v.compare_at // "-"), "-", "-", "(no selling plan)"] | @tsv
  else
    $v.plans[] | [$v.handle, $v.variant, $v.one_time, ($v.compare_at // "-"), .per_delivery, ((.rate_pct|tostring) + "%"), (.plan_name // "-")] | @tsv
  end' <<<"$rows" |
  while IFS=$'\t' read -r h v o c s r p; do
    printf '%-34s %-14s %10s %10s %10s %8s  %s\n' "${h:0:34}" "${v:0:14}" "$o" "$c" "$s" "$r" "$p"
  done
