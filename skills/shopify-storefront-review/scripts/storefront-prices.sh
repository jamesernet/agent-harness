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
# A prepaid plan's per_delivery_price is the whole prepaid amount, so no rate
# is derivable from it; it is printed as "prepaid" rather than as a negative
# percentage that would read as a finding. requires_selling_plan is carried
# through: a subscription-only product has no purchasable one-time price.
#
# Redirects are followed (-L). A host that is not a Shopify storefront answers
# 404 for every handle, exactly like a wrong handle; when no row at all could
# be read the script exits 4 and says so, so an empty table is never mistaken
# for "no selling plans".
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
  code="$(curl -sSL --max-time 20 -o "$body" -w '%{http_code}' -A 'storefront-prices/1 (read-only pricing audit; github.com/jamesernet/agent-harness)' "$url" 2>/dev/null || true)"
  code="${code:-000}"
  if [[ "$code" == "429" ]]; then
    echo "error: HTTP 429 on $url — rate limited. Stop, wait, re-run; do not read an empty body as 'no plans'." >&2
    rm -f "$body"
    exit 3
  fi
  if [[ "$code" != "200" ]]; then
    case "$code" in
      404) why="wrong handle, unpublished product, or not a Shopify storefront" ;;
      403) why="refused — bot protection or a WAF; this is a fact for the report, not an absence of plans" ;;
      000) why="no response (DNS, TLS or timeout)" ;;
      *) why="unexpected status" ;;
    esac
    echo "warning: HTTP $code on $url — skipped ($why)" >&2
    rm -f "$body"
    continue
  fi
  if ! jq -e '.variants' "$body" >/dev/null 2>&1; then
    echo "warning: $url did not return a Shopify product document — not a Shopify storefront?" >&2
    rm -f "$body"
    continue
  fi
  row="$(jq -c --arg handle "$handle" '
    def money: if . == null then null else
      ((. / 100 | floor | tostring) + "." + ((. % 100) | if . < 10 then "0" + tostring else tostring end)) end;
    .requires_selling_plan as $rsp |
    .variants[] | .price as $vp | {
      handle: $handle,
      variant: .title,
      variant_id: .id,
      one_time: ($vp | money),
      requires_selling_plan: ($rsp // false),
      compare_at: (.compare_at_price | money),
      plans: [ .selling_plan_allocations[]? | {
        plan_id: .selling_plan_id,
        group_id: .selling_plan_group_id,
        per_delivery: (.per_delivery_price | money),
        prepaid: (.per_delivery_price != null and .per_delivery_price > $vp),
        rate_pct: (if .per_delivery_price and $vp > 0 and .per_delivery_price <= $vp
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

if [[ "$(jq 'length' <<<"$rows")" == "0" ]]; then
  echo "error: no product could be read from $host — wrong handles, a blocked fetch, or not a Shopify storefront. Nothing here says anything about selling plans." >&2
  exit 4
fi

if [[ "$json" -eq 1 ]]; then
  jq . <<<"$rows"
  exit 0
fi

printf '%-34s %-14s %10s %10s %10s %8s  %s\n' handle variant one_time compare_at subscribed rate plan
jq -r '.[] | . as $v |
  ($v.one_time + (if $v.requires_selling_plan then "*" else "" end)) as $ot |
  if ($v.plans | length) == 0 then
    [$v.handle, $v.variant, $ot, ($v.compare_at // "-"), "-", "-", "(no selling plan)"] | @tsv
  else
    $v.plans[] | [$v.handle, $v.variant, $ot, ($v.compare_at // "-"), (.per_delivery // "-"),
      (if .prepaid then "prepaid" elif .rate_pct == null then "-" else ((.rate_pct|tostring) + "%") end),
      (.plan_name // "-")] | @tsv
  end' <<<"$rows" |
  while IFS=$'\t' read -r h v o c s r p; do
    printf '%-34s %-14s %10s %10s %10s %8s  %s\n' "${h:0:34}" "${v:0:14}" "$o" "$c" "$s" "$r" "$p"
  done
if jq -e 'any(.[]; .requires_selling_plan)' <<<"$rows" >/dev/null; then
  echo "* subscription-only product: the one-time price is not purchasable"
fi
