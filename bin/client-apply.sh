#!/usr/bin/env bash
set -euo pipefail

# Render a work context's Claude model policy into its registered account.
#
#   llmctx context apply <profile.toml>            write
#   llmctx context apply <profile.toml> --check    report drift, change nothing
#   llmctx client apply ...                        compatibility alias
#
# This is deliberately narrow: it reads only [providers.claude] (or the legacy
# [ai] table) and writes only the three settings keys its account, models, and
# max_effort fields map
# to — availableModels, enforceAvailableModels, maxEffortLevel — into
# <account>/settings.json. Every other key in that file is preserved, which is
# the same contract build-adapters.sh keeps for the portable keys.
#
# Why these three and nothing else yet: "which models ran against this client's
# code, and how hard" is the contract-shaped question nothing on the machine
# answered. The rest of the profile (identity, SSO, kube) waits for a second
# real client, as the template says.
#
# The TOML read is a flat-key awk over one table, not a parser. The [ai] keys
# are scalars and one string array by design; anything fancier belongs in a
# real parser, and this tool should fail loudly rather than guess.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/accounts.sh
source "$SCRIPT_DIR/lib/accounts.sh"

usage() {
  echo "usage: llmctx context apply <profile.toml> [--check]" >&2
  exit 2
}

profile=""
check=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --check) check=1 ;;
    -*) usage ;;
    *)
      [[ -z "$profile" ]] || usage
      profile="$1"
      ;;
  esac
  shift
done
[[ -n "$profile" ]] || usage
[[ -f "$profile" ]] || {
  echo "error: no such profile: $profile" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required" >&2
  exit 1
}

# One table, flat keys. New contexts use [providers.claude]; legacy client
# profiles use [ai]. Comments after a value are stripped; quoted strings and a
# one-line string array are the only shapes accepted.
claude_key() {
  awk -v key="$1" '
    /^[[:space:]]*\[/ {
      in_provider = ($0 ~ /^[[:space:]]*\[providers\.claude\][[:space:]]*(#.*)?$/)
      in_ai = ($0 ~ /^[[:space:]]*\[ai\][[:space:]]*(#.*)?$/)
      next
    }
    (in_provider || in_ai) && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "")
      sub(/[[:space:]]*#.*$/, "")
      if (in_provider) { found_provider = 1; print; exit }
      legacy = $0
    }
    END {
      if (!found_provider && legacy != "") print legacy
    }' "$profile"
}
unquote() { printf '%s' "$1" | sed -E 's/^"(.*)"$/\1/'; }

slug="$(awk '
  /^[[:space:]]*\[/ {
    in_client = ($0 ~ /^[[:space:]]*\[client\]/)
    in_context = ($0 ~ /^[[:space:]]*\[context\]/)
    next
  }
  in_client && /^[[:space:]]*slug[[:space:]]*=/ {
    sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); gsub(/"/, ""); print; exit
  }
  in_context && /^[[:space:]]*id[[:space:]]*=/ {
    sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); gsub(/"/, ""); print; exit
  }' "$profile")"
mode_raw="$(claude_key mode)"
account_raw="$(claude_key account)"
models_raw="$(claude_key models)"
effort_raw="$(claude_key max_effort)"

if [[ "$(unquote "$mode_raw")" == "disabled" ]]; then
  echo "error: Claude is disabled in $profile — there is no account policy to apply" >&2
  exit 1
fi

[[ -n "$account_raw" ]] || {
  echo "error: Claude account is not set in $profile — the policy needs a registered home to land in" >&2
  exit 1
}
account="$(unquote "$account_raw")"

policy='{}'
if [[ -n "$models_raw" ]]; then
  case "$models_raw" in
    \[*\]) ;;
    *)
      echo "error: [ai].models must be a one-line string array, e.g. [\"opus\", \"sonnet\"]" >&2
      exit 1
      ;;
  esac
  models_json="$(printf '%s' "$models_raw" | tr -d ' ' | sed -E 's/,\]/]/')"
  # Aliases Claude Code's own /model accepts, with an optional context suffix
  # such as sonnet[1m]; or a full claude-* id.
  jq -e 'type == "array" and length > 0 and all(.[]; type == "string" and test("^((sonnet|opus|haiku|fable|default|opusplan)(\\[[0-9]+m\\])?|claude-[a-z0-9.-]+)$"))' \
    <<<"$models_json" >/dev/null 2>&1 || {
    echo "error: [ai].models must be a non-empty array of model aliases or claude-* ids: $models_raw" >&2
    exit 1
  }
  policy="$(jq -c --argjson m "$models_json" '. + {availableModels: $m, enforceAvailableModels: true}' <<<"$policy")"
fi
# All three keys are always managed. A profile that drops `models` means "no
# restriction", so the restriction is removed; a stale allowlist that
# drift-checks clean is the wrong default for a tool whose job is to say which
# models may run against a client's code.
remove='[]'
[[ -n "$models_raw" ]] || remove="$(jq -c '. + ["availableModels","enforceAvailableModels"]' <<<"$remove")"
[[ -n "$effort_raw" ]] || remove="$(jq -c '. + ["maxEffortLevel"]' <<<"$remove")"
if [[ -n "$effort_raw" ]]; then
  effort="$(unquote "$effort_raw")"
  case "$effort" in
    low | medium | high | xhigh | max) ;;
    *)
      echo "error: [ai].max_effort must be low|medium|high|xhigh|max, got \"$effort\"" >&2
      exit 1
      ;;
  esac
  policy="$(jq -c --arg e "$effort" '. + {maxEffortLevel: $e}' <<<"$policy")"
fi
[[ "$policy" != '{}' ]] || {
  echo "error: [ai] declares neither models nor max_effort in $profile — nothing to apply" >&2
  exit 1
}

# The account must be one this machine knows, or the policy lands nowhere.
account_dir=""
while IFS=$'\t' read -r name dir; do
  [[ "$name" == "$account" ]] && account_dir="$dir" && break
done < <(llmctx_accounts)
[[ -n "$account_dir" ]] || {
  echo "error: Claude account \"$account\" is not registered on this machine (llmctx account list)" >&2
  exit 1
}
settings="$account_dir/settings.json"

current='{}'
# -s, not -f: an empty file passed the existence test, jq then produced no
# output for it, and apply reported success while writing nothing.
[[ -s "$settings" ]] && current="$(cat "$settings")"
jq -e 'type == "object"' <<<"$current" >/dev/null 2>&1 || {
  echo "error: $settings is not a JSON object; not touching it" >&2
  exit 1
}
managed_keys='["availableModels","enforceAvailableModels","maxEffortLevel"]'
live_subset="$(jq -c --argjson k "$managed_keys" 'with_entries(select(.key as $x | $k | index($x)))' <<<"$current")"
label="${slug:-$(basename "$profile")} -> $account ($settings)"

if [[ "$check" -eq 1 ]]; then
  if [[ "$(jq -S . <<<"$live_subset")" == "$(jq -S . <<<"$policy")" ]]; then
    echo "current: $label"
    exit 0
  fi
  echo "drift: $label"
  echo "  expected: $policy"
  echo "  actual:   $live_subset"
  exit 1
fi

mkdir -p "$account_dir"
tmp="$(mktemp "$account_dir/.llmctx-context.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
jq --argjson p "$policy" --argjson r "$remove" '. * $p | delpaths($r | map([.]))' <<<"$current" >"$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$settings"
trap - EXIT
echo "applied: $label"
echo "  $policy"
