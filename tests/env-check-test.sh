#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$SRC/bin/env-check.sh"
# An absolute bash, so a test that narrows PATH can still launch the script.
BASH="${BASH:-$(command -v bash)}"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-env-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "env-check test failed: $*" >&2
  exit 1
}

# A repo whose declaration is written for us, with no ambient CI or AWS state
# leaking in from the caller.
repo() {
  local dir="$tmp/$1"
  mkdir -p "$dir"
  printf '%s\n' "$2" >"$dir/.llmctx.json"
  printf '%s' "$dir"
}

run() { # dir [mode] -> output on stdout, exit status in $status
  local dir="$1" mode="${2:-check}"
  set +e
  output="$(CI='' HOME="$tmp/home" "$CHECK" "$mode" "$dir" 2>&1)"
  status=$?
  set -e
}

mkdir -p "$tmp/home"

# --- no declaration is not a failure ---------------------------------------
d="$(repo none '{"schemaVersion":1}')"
run "$d"
[[ "$status" -eq 0 ]] || fail "a repo with no environment should pass, got $status"
[[ "$output" == *"declares no environment"* ]] || fail "expected the no-environment message: $output"

# --- no argument: the repository, not the cwd ---------------------------------
# From a subdirectory, the declaration at the root must be found (#58). The
# explicit-argument form stays literal, so a wrapper that names a directory
# keeps meaning that directory.
d="$(repo rooted '{"schemaVersion":1}')"
d="$(cd "$d" && pwd)" # $TMPDIR ends in a slash on macOS; the script prints the normalised path
git -C "$d" init -q
mkdir -p "$d/pkg/deep"
set +e
output="$(cd "$d/pkg/deep" && CI='' HOME="$tmp/home" "$CHECK" check 2>&1)"
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "no-argument check from a subdirectory exited $status: $output"
[[ "$output" == *"declares no environment"* ]] ||
  fail "no-argument check from a subdirectory did not find the root declaration: $output"
run "$d/pkg/deep"
[[ "$output" == *"no .llmctx.json in $d/pkg/deep"* ]] ||
  fail "an explicit subdirectory argument was not taken literally: $output"
# Outside any repository, no argument still means the cwd.
mkdir -p "$tmp/plain"
set +e
output="$(cd "$tmp/plain" && CI='' HOME="$tmp/home" "$CHECK" check 2>&1)"
status=$?
set -e
[[ "$status" -eq 0 && "$output" == *"no .llmctx.json in"* ]] ||
  fail "no-argument check outside a repository did not fall back to the cwd: $output"

# --- no policy file at all --------------------------------------------------
mkdir -p "$tmp/bare"
run "$tmp/bare"
[[ "$status" -eq 0 ]] || fail "a repo with no .llmctx.json should pass, got $status"

# --- an unknown target names the ones that exist ----------------------------
d="$(repo unknown '{"schemaVersion":1,"environment":{"target":"nope"}}')"
run "$d"
[[ "$status" -eq 1 ]] || fail "an unknown target must fail, got $status"
[[ "$output" == *"cloudflare-pages"* ]] || fail "expected the available targets listed: $output"

# --- a Pages site that deploys on push needs no token -----------------------
# The regression this guards: the target lists CLOUDFLARE_API_TOKEN as one it
# MAY need, and checking the target's list instead of the project's reported a
# missing secret for every Pages site that holds no token, which is most.
d="$(repo pages '{"schemaVersion":1,"environment":{"target":"cloudflare-pages"}}')"
touch "$d/_headers" "$d/_redirects"
run "$d"
[[ "$status" -eq 0 ]] || fail "a Pages site with no declared secret should pass: $output"
[[ "$output" != *"CLOUDFLARE_API_TOKEN"* ]] || fail "target secrets must not be checked: $output"

# --- a secret the project DOES declare is checked ---------------------------
d="$(repo pages-token '{"schemaVersion":1,"environment":{"target":"cloudflare-pages","secrets":["CLOUDFLARE_API_TOKEN"]}}')"
touch "$d/_headers" "$d/_redirects"
run "$d"
[[ "$status" -eq 1 ]] || fail "a declared but unbound secret must fail"
[[ "$output" == *"CLOUDFLARE_API_TOKEN"* ]] || fail "expected the secret named: $output"
printf 'export CLOUDFLARE_API_TOKEN=whatever\n' >"$d/.envrc.local"
run "$d"
[[ "$status" -eq 0 ]] || fail "a bound secret should pass: $output"
[[ "$output" != *whatever* ]] || fail "a secret VALUE must never be printed: $output"

# --- required env names must appear in the declaration ----------------------
d="$(repo amplify-bare '{"schemaVersion":1,"environment":{"target":"aws-amplify"}}')"
run "$d"
[[ "$output" == *"env:AWS_PROFILE"*MISSING* || "$output" == *MISSING*"env:AWS_PROFILE"* ]] ||
  [[ "$output" == *"AWS_PROFILE"* ]] || fail "expected AWS_PROFILE reported: $output"
[[ "$status" -eq 1 ]] || fail "a target requiring env names must fail when they are absent"

# --- AWS profile resolution, and the measured CI exemption ------------------
d="$(repo amplify '{"schemaVersion":1,"environment":{"target":"aws-amplify","cloud":{"awsProfile":"acme"}}}')"
touch "$d/amplify.yml"
run "$d"
[[ "$output" == *"~/.aws/config does not exist"* ]] || fail "expected the missing-config finding: $output"
set +e
ci_output="$(CI=1 HOME="$tmp/home" "$CHECK" check "$d" 2>&1)"
set -e
[[ "$ci_output" == *"CI"* ]] || fail "CI must be exempt when ~/.aws/config is absent: $ci_output"
# Where a config DOES exist, the profile is still checked — only the missing
# file is exempt.
mkdir -p "$tmp/home/.aws"
printf '[profile other]\n' >"$tmp/home/.aws/config"
set +e
ci_output="$(CI=1 HOME="$tmp/home" "$CHECK" check "$d" 2>&1)"
ci_status=$?
set -e
[[ "$ci_status" -eq 1 ]] || fail "a present config must still be checked under CI"
printf '[profile acme]\n' >>"$tmp/home/.aws/config"
run "$d"
[[ "$output" == *"configured in ~/.aws/config"* ]] || fail "expected the profile to resolve: $output"

# --- two sources of truth for one Cloudflare account ------------------------
d="$(repo workers '{"schemaVersion":1,"environment":{"target":"other","cloud":{"cloudflareAccount":"deadbeef"}}}')"
run "$d"
[[ "$output" == *"no wrangler config"* ]] || fail "expected the no-wrangler note: $output"
printf '{"account_id":"cafe"}\n' >"$d/wrangler.jsonc"
run "$d"
[[ "$status" -eq 1 ]] || fail "a disagreeing wrangler account must fail"
[[ "$output" == *CONFLICT* ]] || fail "expected CONFLICT: $output"
printf '{"account_id":"deadbeef"}\n' >"$d/wrangler.jsonc"
run "$d"
[[ "$output" == *"agrees with wrangler.jsonc"* ]] || fail "expected agreement: $output"

# --- the three findings a mutation test showed were uncovered ---------------
# Each of these passed with `add MISSING` flipped to `add OK`, which means the
# assertion was reading some other line. They now name the status.
d="$(repo missing-env '{"schemaVersion":1,"environment":{"target":"aws-amplify"}}')"
touch "$d/amplify.yml"
run "$d"
[[ "$output" == *"MISSING  env:AWS_PROFILE"* ]] || fail "an undeclared required name must be MISSING, not merely mentioned: $output"

d="$(repo missing-file '{"schemaVersion":1,"environment":{"target":"aws-amplify","cloud":{"awsProfile":"acme"}}}')"
run "$d"
[[ "$output" == *"MISSING  file:amplify.yml"* ]] || fail "an absent check_file must be MISSING: $output"

d="$(repo missing-cli '{"schemaVersion":1,"environment":{"target":"aws-amplify","cloud":{"awsProfile":"acme"}}}')"
touch "$d/amplify.yml"
# A PATH holding exactly what the script needs and NOT aws. Emptying PATH
# outright does not test this branch — it breaks dirname on line 18 and the
# script never reaches the cli check at all.
mkdir -p "$tmp/minbin"
for tool in dirname basename jq sed grep find head tr sort git; do
  real="$(command -v "$tool" 2>/dev/null)" || continue
  ln -sf "$real" "$tmp/minbin/$tool"
done
command -v aws >/dev/null 2>&1 || fail "this test needs aws present to prove its absence is detected"
set +e
cli_output="$(PATH="$tmp/minbin" CI='' HOME="$tmp/home" "$BASH" "$CHECK" check "$d" 2>&1)"
set -e
[[ "$cli_output" == *"MISSING  cli:aws"* ]] || fail "a required cli absent from PATH must be MISSING: $cli_output"

# --- a reference in secrets says so, rather than falling through to NAMES ----
# The reference rule sat after the NAMES rule, where no string containing ://
# could reach it. Deleting it left the suite green, because this assertion
# checked the wrong message.
d="$(repo ref '{"schemaVersion":1,"environment":{"target":"other","secrets":["op://Vault/Item/f"]}}')"
run "$d"
[[ "$status" -eq 2 ]] || fail "a vault reference must be rejected, got $status"
[[ "$output" == *"must not contain references"* ]] || fail "expected the reference message, not the NAMES one: $output"

# --- every field is constrained, not just secrets ---------------------------
# The validator checked secrets alone, so a vault path in cloud.awsProfile, an
# SSO URL in cloud, and a key id in tools were all accepted and then printed
# back by explain under a line reading "Nothing here is a credential".
while IFS='|' read -r label json; do
  [[ -z "$label" ]] && continue
  d="$(repo "smuggle-$label" "$json")"
  run "$d"
  [[ "$status" -eq 2 ]] || fail "$label must be rejected by the validator, got $status"
done <<'SMUGGLE'
vault-in-cloud|{"schemaVersion":1,"environment":{"target":"other","cloud":{"awsProfile":"op://Clients/ACME/profile"}}}
sso-url|{"schemaVersion":1,"environment":{"target":"other","cloud":{"ssoStart":"https://d-9abc.awsapps.com/start"}}}
live-key|{"schemaVersion":1,"environment":{"target":"other","cloud":{"apiKey":"sk-live-abc123"}}}
akia-in-tools|{"schemaVersion":1,"environment":{"target":"other","tools":["AKIAIOSFODNN7EXAMPLE"]}}
creds-in-mcp|{"schemaVersion":1,"environment":{"target":"other","mcp":["https://u:pw@mcp.acme.internal/sse"]}}
leading-dash|{"schemaVersion":1,"environment":{"target":"other","cloud":{"cloudflareAccount":"-r"}}}
SMUGGLE

# --- jq test() raises on a non-string, and an unguarded capture fails OPEN ---
for bad in '[{"op":"vault://x"}]' '[123]' '[null]'; do
  d="$(repo "nonstring-$RANDOM" "{\"schemaVersion\":1,\"environment\":{\"target\":\"other\",\"secrets\":$bad}}")"
  run "$d"
  [[ "$status" -eq 2 ]] || fail "secrets $bad must be rejected, got $status"
done

# --- a legitimate full declaration still passes -----------------------------
# awsProfile is `acme` because the fake HOME above has exactly that profile:
# the point is that every field is populated AND every check resolves.
d="$(repo legit '{"schemaVersion":1,"environment":{"target":"cloudflare-pages","cloud":{"awsProfile":"acme","awsRegion":"us-west-2","cloudflareAccount":"a1b2c3d4e5f6"},"tools":["playwright","wrangler"],"mcp":["cloudflare"],"skills":"website"}}')"
touch "$d/_headers" "$d/_redirects"
run "$d"
[[ "$status" -eq 0 ]] || fail "a legitimate full declaration must pass: $output"

# --- the account match is exact, not a substring ----------------------------
# Measured before the fix: an id mentioned in a migration comment reported
# agreement with the account the project had moved away from.
d="$(repo cfsubstring '{"schemaVersion":1,"environment":{"target":"other","cloud":{"cloudflareAccount":"a1b2c3d4"}}}')"
printf '{"account_id":"0000ffff"}\n// moved off account a1b2c3d4 in 2024\n' >"$d/wrangler.jsonc"
run "$d"
[[ "$output" == *CONFLICT* ]] || fail "a substring match in a comment must not read as agreement: $output"

# --- a committed .envrc.local is the thing the section exists to prevent ----
d="$(repo tracked '{"schemaVersion":1,"environment":{"target":"other","secrets":["SOME_TOKEN"]}}')"
git -C "$d" init -q 2>/dev/null || true
printf 'export SOME_TOKEN=x\n' >"$d/.envrc.local"
git -C "$d" add .envrc.local >/dev/null 2>&1
run "$d"
# Assert the STATUS, not just the message. Matching "tracked by git" alone
# passed with CONFLICT flipped to OK, which is the whole of what the assertion
# was meant to catch.
[[ "$output" == *"CONFLICT"*"secret:storage"* ]] || fail "a committed .envrc.local must be a CONFLICT: $output"
[[ "$status" -eq 1 ]] || fail "a committed .envrc.local must fail the check, got $status"

# --- explain is read-only and prints the manual steps -----------------------
d="$(repo explain '{"schemaVersion":1,"environment":{"target":"cloudflare-pages"}}')"
run "$d" explain
[[ "$status" -eq 0 ]] || fail "explain must succeed: $output"
[[ "$output" == *"Still manual"* ]] || fail "explain must print the manual steps: $output"
[[ "$output" == *"onboard"* ]] || fail "explain must print the onboard hint: $output"

# --- an invalid declaration is rejected by the policy validator -------------
# A lowercase entry is a value-shaped name and gets the NAMES message. A
# reference gets its own, more specific message; that case is asserted above.
# This assertion used to sit on the reference and expect NAMES, which is how
# the reference rule stayed dead without any test noticing.
d="$(repo badsecret '{"schemaVersion":1,"environment":{"target":"other","secrets":["token"]}}')"
run "$d"
[[ "$status" -eq 2 ]] || fail "a value-shaped secret name must be rejected, got $status"
[[ "$output" == *"NAMES"* ]] || fail "expected the names-not-values error: $output"

# --- every shipped target file parses and declares a description ------------
for conf in "$SRC"/targets/*.conf; do
  name="$(basename "$conf")"
  body="$(cat "$conf")"
  grep -qE '^description=.+' "$conf" || fail "$name has no description"
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[a-z_]+= ]] || fail "$name: not key=value: $line"
  done <<<"$body"
done

echo "env-check tests: passed"
