#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../bin/lib/policy.sh
source "$SRC/bin/lib/policy.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-policy-test.XXXXXX")"
repo="$tmp/repo"
global_config="$tmp/global.gitconfig"
mkdir -p "$repo"
git -C "$repo" init -q
export GIT_CONFIG_GLOBAL="$global_config"

fail() {
  echo "policy test failed: $*" >&2
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}

llmctx_policy_resolve "$repo"
assert_eq "$LLMCTX_PROFILE" personal
assert_eq "$LLMCTX_BRANCH_POLICY" remind
assert_eq "$LLMCTX_PROTECTED_BRANCHES" "main master"
assert_eq "$LLMCTX_IRREVERSIBLE_POLICY" ask
assert_eq "$LLMCTX_IRREVERSIBLE_POLICY_SOURCE" "built-in"

printf '%s\n' '{"schemaVersion":1,"profile":"client","protectedBranches":["main","stage"]}' >"$repo/.llmctx.json"
llmctx_policy_resolve "$repo"
assert_eq "$LLMCTX_PROFILE" client
assert_eq "$LLMCTX_PROFILE_SOURCE" repo-policy
assert_eq "$LLMCTX_BRANCH_POLICY" deny
assert_eq "$LLMCTX_BRANCH_POLICY_SOURCE" built-in:client
assert_eq "$LLMCTX_PROTECTED_BRANCHES" "main stage"

git config --global llmctx.branchPolicy ask
llmctx_policy_resolve "$repo"
assert_eq "$LLMCTX_BRANCH_POLICY" ask
assert_eq "$LLMCTX_BRANCH_POLICY_SOURCE" git-global

git -C "$repo" config --local llmctx.profile personal
git -C "$repo" config --local llmctx.branchPolicy off
git -C "$repo" config --local llmctx.protectedBranches "trunk release"
llmctx_policy_resolve "$repo"
assert_eq "$LLMCTX_PROFILE" personal
assert_eq "$LLMCTX_PROFILE_SOURCE" git-local
assert_eq "$LLMCTX_BRANCH_POLICY" off
assert_eq "$LLMCTX_BRANCH_POLICY_SOURCE" git-local
assert_eq "$LLMCTX_PROTECTED_BRANCHES" "trunk release"

printf '%s\n' '{"schemaVersion":99,"profile":"client"}' >"$repo/.llmctx.json"
if llmctx_policy_resolve "$repo"; then
  fail "unsupported schemaVersion was accepted"
fi
[[ "$LLMCTX_POLICY_ERROR" == *"unsupported schemaVersion"* ]] ||
  fail "unexpected validation error: $LLMCTX_POLICY_ERROR"

# environment: names only, never a value or a vault reference. The validator is
# the gate that keeps a client identity map out of a repo the client can read.
printf '%s\n' '{"schemaVersion":1,"environment":{"target":"cloudflare-pages","cloud":{"cloudflareAccount":"abc"},"secrets":["CLOUDFLARE_API_TOKEN"]}}' >"$repo/.llmctx.json"
llmctx_policy_validate "$repo" || fail "a names-only environment should validate: $LLMCTX_POLICY_ERROR"

printf '%s\n' '{"schemaVersion":1,"environment":{"target":"cloudflare-pages","secrets":["op://Vault/Item/field"]}}' >"$repo/.llmctx.json"
llmctx_policy_validate "$repo" && fail "a vault reference in secrets must be rejected"

printf '%s\n' '{"schemaVersion":1,"environment":{"target":"Not A Slug"}}' >"$repo/.llmctx.json"
llmctx_policy_validate "$repo" && fail "a non-slug target must be rejected"

printf '%s\n' '{"schemaVersion":1,"environment":{"cloud":{"awsProfile":"x"}}}' >"$repo/.llmctx.json"
llmctx_policy_validate "$repo" && fail "an environment without a target must be rejected"

rm -f "$repo/.llmctx.json"

# --- mergePolicy: the same four tiers, read by skills rather than hooks ------
#
# What a session may do with a pull request it has finished. The default is
# `hold` for both profiles: a merge is where a person in the loop costs least,
# so the cautious answer is what saying nothing gets you. Validated by value,
# unlike briefs/claudeImport, because a misspelling should be heard from
# `repo diff` rather than silently ignored by the skill meant to obey it.

mrepo="$tmp/mergerepo"
mkdir -p "$mrepo"
git -C "$mrepo" init -q

llmctx_policy_resolve "$mrepo" || fail "resolve failed with nothing declared: $LLMCTX_POLICY_ERROR"
[[ "$LLMCTX_MERGE_POLICY" == hold ]] || fail "built-in mergePolicy was $LLMCTX_MERGE_POLICY, expected hold"
[[ "$LLMCTX_MERGE_POLICY_SOURCE" == built-in ]] || fail "built-in source was $LLMCTX_MERGE_POLICY_SOURCE"

# ...for a client profile too: unlike branchPolicy, this is not a strictness dial.
printf '%s\n' '{"schemaVersion":1,"profile":"client"}' >"$mrepo/.llmctx.json"
llmctx_policy_resolve "$mrepo" || fail "resolve failed for a client profile: $LLMCTX_POLICY_ERROR"
[[ "$LLMCTX_MERGE_POLICY" == hold ]] || fail "client default mergePolicy was $LLMCTX_MERGE_POLICY, expected hold"

for v in hold review-and-merge queue; do
  printf '{"schemaVersion":1,"mergePolicy":"%s"}\n' "$v" >"$mrepo/.llmctx.json"
  llmctx_policy_resolve "$mrepo" || fail "resolve failed for mergePolicy $v: $LLMCTX_POLICY_ERROR"
  [[ "$LLMCTX_MERGE_POLICY" == "$v" ]] || fail "committed mergePolicy $v resolved as $LLMCTX_MERGE_POLICY"
  [[ "$LLMCTX_MERGE_POLICY_SOURCE" == repo-policy ]] || fail "committed source was $LLMCTX_MERGE_POLICY_SOURCE"
done

# An invalid value is LOUD, at validation, before anything resolves.
printf '%s\n' '{"schemaVersion":1,"mergePolicy":"merge-it-and-hope"}' >"$mrepo/.llmctx.json"
if llmctx_policy_resolve "$mrepo" 2>/dev/null; then
  fail "an invalid mergePolicy resolved instead of erroring"
fi
[[ "$LLMCTX_POLICY_ERROR" == *"invalid mergePolicy"* ]] ||
  fail "the error did not name the key: $LLMCTX_POLICY_ERROR"

# Tier order: repo-local git config outranks the committed file, which
# outranks global config.
printf '%s\n' '{"schemaVersion":1,"mergePolicy":"queue"}' >"$mrepo/.llmctx.json"
git config --global llmctx.mergePolicy review-and-merge
llmctx_policy_resolve "$mrepo" || fail "resolve failed with a global set: $LLMCTX_POLICY_ERROR"
[[ "$LLMCTX_MERGE_POLICY" == queue ]] || fail "the committed file did not outrank global config"
rm -f "$mrepo/.llmctx.json"
llmctx_policy_resolve "$mrepo" || fail "resolve failed with only a global set: $LLMCTX_POLICY_ERROR"
[[ "$LLMCTX_MERGE_POLICY" == review-and-merge && "$LLMCTX_MERGE_POLICY_SOURCE" == git-global ]] ||
  fail "global mergePolicy was $LLMCTX_MERGE_POLICY (source $LLMCTX_MERGE_POLICY_SOURCE)"
git -C "$mrepo" config --local llmctx.mergePolicy hold
llmctx_policy_resolve "$mrepo" || fail "resolve failed with a local set: $LLMCTX_POLICY_ERROR"
[[ "$LLMCTX_MERGE_POLICY" == hold && "$LLMCTX_MERGE_POLICY_SOURCE" == git-local ]] ||
  fail "repo-local mergePolicy did not win: $LLMCTX_MERGE_POLICY ($LLMCTX_MERGE_POLICY_SOURCE)"
git -C "$mrepo" config --local --unset llmctx.mergePolicy
git config --global --unset llmctx.mergePolicy

# A typo in an unrelated key must not decide this one: resolved on its own,
# the way irreversiblePolicy is.
printf '%s\n' '{"schemaVersion":1,"branchPolicy":"stirct","mergePolicy":"queue"}' >"$mrepo/.llmctx.json"
llmctx_policy_resolve_merge "$mrepo" || fail "resolve_merge failed behind a bad branchPolicy: $LLMCTX_POLICY_ERROR"
[[ "$LLMCTX_MERGE_POLICY" == queue ]] || fail "a typo in branchPolicy changed mergePolicy to $LLMCTX_MERGE_POLICY"
rm -f "$mrepo/.llmctx.json"

# --- irreversiblePolicy: the same four tiers, a different default -----------
#
# In its OWN repository. Earlier cases in this file leave local and global
# overrides behind on purpose, and asserting a default against that state would
# be asserting against test order rather than against the resolver.
irepo="$tmp/irrev"
mkdir -p "$irepo"
git -C "$irepo" init -q
# Its own global config as well as its own repository: this block asserts what
# the resolver does, which means nothing an earlier case set may still be
# visible at any tier.
GIT_CONFIG_GLOBAL="$tmp/irrev.gitconfig"
: >"$GIT_CONFIG_GLOBAL"

# The built-in is `ask` for BOTH profiles, deliberately unlike branchPolicy —
# which the same resolve call shows deriving `deny` from the client profile.
printf '%s\n' '{"schemaVersion":1,"profile":"client"}' >"$irepo/.llmctx.json"
llmctx_policy_resolve "$irepo"
assert_eq "$LLMCTX_BRANCH_POLICY" deny
assert_eq "$LLMCTX_IRREVERSIBLE_POLICY" ask
assert_eq "$LLMCTX_IRREVERSIBLE_POLICY_SOURCE" "built-in"

printf '%s\n' '{"schemaVersion":1,"profile":"personal"}' >"$irepo/.llmctx.json"
llmctx_policy_resolve "$irepo"
assert_eq "$LLMCTX_IRREVERSIBLE_POLICY" ask

# global < repo-policy < git-local
git config --global llmctx.irreversiblePolicy off
llmctx_policy_resolve "$irepo"
assert_eq "$LLMCTX_IRREVERSIBLE_POLICY" off
assert_eq "$LLMCTX_IRREVERSIBLE_POLICY_SOURCE" "git-global"

printf '%s\n' '{"schemaVersion":1,"irreversiblePolicy":"deny"}' >"$irepo/.llmctx.json"
llmctx_policy_resolve "$irepo"
assert_eq "$LLMCTX_IRREVERSIBLE_POLICY" deny
assert_eq "$LLMCTX_IRREVERSIBLE_POLICY_SOURCE" "repo-policy"

git -C "$irepo" config --local llmctx.irreversiblePolicy ask
llmctx_policy_resolve "$irepo"
assert_eq "$LLMCTX_IRREVERSIBLE_POLICY" ask
assert_eq "$LLMCTX_IRREVERSIBLE_POLICY_SOURCE" "git-local"
git -C "$irepo" config --local --unset llmctx.irreversiblePolicy
git config --global --unset llmctx.irreversiblePolicy

# An invalid value is rejected by validation, so every consumer fails open
# rather than acting on a value nobody meant.
printf '%s\n' '{"schemaVersion":1,"irreversiblePolicy":"sometimes"}' >"$irepo/.llmctx.json"
if llmctx_policy_validate "$irepo"; then
  fail "an invalid irreversiblePolicy was accepted"
fi
[[ "$LLMCTX_POLICY_ERROR" == *irreversiblePolicy* ]] ||
  fail "the error does not name the field: $LLMCTX_POLICY_ERROR"

GIT_CONFIG_GLOBAL="$global_config"

echo "policy tests: passed"
