#!/usr/bin/env bash
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-global-includes.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
export HOME="$tmp/home" GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME/work" "$HOME/.claude-acme"
git config --file "$GIT_CONFIG_GLOBAL" include.path "$tmp/state.gitconfig"
git config --file "$tmp/state.gitconfig" llmctx.claudeAccount "acme=$HOME/.claude-acme"
git config --file "$tmp/state.gitconfig" llmctx.skillBundle core
git config --file "$tmp/state.gitconfig" llmctx.skillBundle.acme fintech
git config --file "$tmp/state.gitconfig" llmctx.accountRoute "acme=$HOME/work"
git config --file "$tmp/state.gitconfig" llmctx.branchPolicy deny
git config --file "$tmp/state.gitconfig" llmctx.mergePolicy review-and-merge
git config --file "$tmp/state.gitconfig" llmctx.irreversiblePolicy deny
git config --file "$tmp/state.gitconfig" llmctx.protectedBranches release

fail() {
  echo "global includes test failed: $*" >&2
  exit 1
}

"$SRC/bin/llmctx" account list | grep -q '^acme ' || fail "included account was ignored"
# Repository config must not register accounts or widen the machine bundle.
git -C "$HOME/work" init -q
git -C "$HOME/work" config llmctx.claudeAccount "untrusted=$HOME/.claude-untrusted"
git -C "$HOME/work" config llmctx.skillBundle all
(
  cd "$HOME/work"
  ! "$SRC/bin/llmctx" account list | grep -q '^untrusted ' || fail "repository account was trusted"
  "$SRC/bin/install-skills.sh" >/dev/null
)
[[ -d "$HOME/.claude/skills/codebase-design" ]] || fail "included core bundle was ignored"
[[ ! -e "$HOME/.claude/skills/review-kyc-aml" ]] || fail "default bundle was widened"
[[ -d "$HOME/.claude-acme/skills/review-kyc-aml" ]] || fail "account bundle was ignored"

# shellcheck source=../bin/lib/routes.sh
source "$SRC/bin/lib/routes.sh"
[[ "$(llmctx_routes_match "$HOME/work")" == acme$'\t'* ]] || fail "included route was ignored"
# shellcheck source=../bin/lib/policy.sh
source "$SRC/bin/lib/policy.sh"
llmctx_policy_resolve "$HOME/work"
[[ "$LLMCTX_BRANCH_POLICY" == deny ]] || fail "included branch policy was ignored"
[[ "$LLMCTX_MERGE_POLICY" == review-and-merge ]] || fail "included merge policy was ignored"
[[ "$LLMCTX_IRREVERSIBLE_POLICY" == deny ]] || fail "included irreversible policy was ignored"
[[ "$LLMCTX_PROTECTED_BRANCHES" == release ]] || fail "included protected branches were ignored"

"$SRC/bin/doctor.sh" --json >"$tmp/doctor.json" || true
for id in claude-skills 'claude-skills[acme]' codex-skills skill-bundle; do
  jq -e --arg id "$id" 'any(.checks[]; .id == $id and .status == "PASS")' \
    "$tmp/doctor.json" >/dev/null || fail "doctor ignored included settings for $id"
done
echo "global includes tests: passed"
