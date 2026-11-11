#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$SRC/bin/llmctx"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-cli-test.XXXXXX")"
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q
export GIT_CONFIG_GLOBAL="$tmp/global.gitconfig"

fail() {
  echo "cli test failed: $*" >&2
  exit 1
}

printf '%s\n' '{"schemaVersion":1,"profile":"client","protectedBranches":["main","stage"]}' >"$repo/.llmctx.json"

output="$($CLI explain profile "$repo")"
[[ "$output" == "profile = client (source: repo-policy)" ]] || fail "$output"
output="$($CLI explain branchPolicy "$repo")"
[[ "$output" == "branchPolicy = deny (source: built-in:client)" ]] || fail "$output"
output="$($CLI explain protectedBranches "$repo")"
[[ "$output" == "protectedBranches = main stage (source: repo-policy)" ]] || fail "$output"

# The second tenant on the same ladder. Note the profile is `client` here and
# branchPolicy resolved to deny above, while this stays `ask` — the default is
# deliberately not profile-derived.
output="$($CLI explain irreversiblePolicy "$repo")"
[[ "$output" == "irreversiblePolicy = ask (source: built-in)" ]] || fail "$output"

git -C "$repo" config --local llmctx.branchPolicy off
output="$($CLI explain branchPolicy "$repo")"
[[ "$output" == "branchPolicy = off (source: git-local)" ]] || fail "$output"

git -C "$repo" config --local llmctx.irreversiblePolicy deny
output="$($CLI explain irreversiblePolicy "$repo")"
[[ "$output" == "irreversiblePolicy = deny (source: git-local)" ]] || fail "$output"
git -C "$repo" config --local --unset llmctx.irreversiblePolicy

if "$CLI" explain unknown "$repo" >/dev/null 2>&1; then
  fail "unknown setting was accepted"
fi

echo "cli tests: passed"
