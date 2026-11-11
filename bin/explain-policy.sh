#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/policy.sh
source "$SCRIPT_DIR/lib/policy.sh"

setting="${1:-}"
repo_path="${2:-.}"
case "$setting" in
  profile | branchPolicy | irreversiblePolicy | protectedBranches) ;;
  *)
    echo "usage: llmctx explain <profile|branchPolicy|irreversiblePolicy|protectedBranches> [repo]" >&2
    exit 2
    ;;
esac

root="$(git -C "$repo_path" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "not a git repository: $repo_path" >&2
  exit 2
}
llmctx_policy_resolve "$root" || {
  echo "$LLMCTX_POLICY_ERROR" >&2
  exit 1
}

case "$setting" in
  profile)
    value="$LLMCTX_PROFILE"
    source_name="$LLMCTX_PROFILE_SOURCE"
    ;;
  branchPolicy)
    value="$LLMCTX_BRANCH_POLICY"
    source_name="$LLMCTX_BRANCH_POLICY_SOURCE"
    ;;
  irreversiblePolicy)
    value="$LLMCTX_IRREVERSIBLE_POLICY"
    source_name="$LLMCTX_IRREVERSIBLE_POLICY_SOURCE"
    ;;
  protectedBranches)
    value="$LLMCTX_PROTECTED_BRANCHES"
    source_name="$LLMCTX_PROTECTED_BRANCHES_SOURCE"
    ;;
esac

printf '%s = %s (source: %s)\n' "$setting" "$value" "$source_name"
