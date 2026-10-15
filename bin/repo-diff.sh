#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/policy.sh
source "$SCRIPT_DIR/lib/policy.sh"

repo_path="."
output_json=0
for arg in "$@"; do
  case "$arg" in
    --json) output_json=1 ;;
    -*)
      echo "usage: llmctx repo diff [repo] [--json]" >&2
      exit 2
      ;;
    *) repo_path="$arg" ;;
  esac
done

root="$(git -C "$repo_path" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "not a git repository: $repo_path" >&2
  exit 2
}
findings="$(mktemp "${TMPDIR:-/tmp}/llmctx-findings.XXXXXX")"
trap 'rm -f "$findings"' EXIT
failures=0

add_finding() {
  local id="$1" status="$2" expected="$3" actual="$4" source_name="$5" remediation="$6"
  jq -cn \
    --arg id "$id" \
    --arg status "$status" \
    --arg expected "$expected" \
    --arg actual "$actual" \
    --arg source "$source_name" \
    --arg remediation "$remediation" \
    '{id:$id,status:$status,expected:$expected,actual:$actual,source:$source,remediation:$remediation}' \
    >>"$findings"
  case "$status" in MISSING | CONFLICT | STALE) failures=$((failures + 1)) ;; esac
}

if llmctx_policy_resolve "$root"; then
  profile_status=OK
  branch_status=OK
  protected_status=OK
  [[ "$LLMCTX_PROFILE_SOURCE" == "git-local" ]] && profile_status=OVERRIDE
  [[ "$LLMCTX_BRANCH_POLICY_SOURCE" == "git-local" ]] && branch_status=OVERRIDE
  [[ "$LLMCTX_PROTECTED_BRANCHES_SOURCE" == "git-local" ]] && protected_status=OVERRIDE
  add_finding profile "$profile_status" "resolved repository profile" "$LLMCTX_PROFILE" "$LLMCTX_PROFILE_SOURCE" ""
  add_finding branch-policy "$branch_status" "resolved branch policy" "$LLMCTX_BRANCH_POLICY" "$LLMCTX_BRANCH_POLICY_SOURCE" ""
  add_finding protected-branches "$protected_status" "resolved protected branches" "$LLMCTX_PROTECTED_BRANCHES" "$LLMCTX_PROTECTED_BRANCHES_SOURCE" ""
else
  add_finding policy CONFLICT "valid schemaVersion $LLMCTX_POLICY_SCHEMA_VERSION policy" "$LLMCTX_POLICY_ERROR" repo-policy "fix or remove $root/.llmctx.json"
fi

if [[ -f "$root/AGENTS.md" ]]; then
  add_finding agents-file OK "canonical project instructions" present repository ""
else
  add_finding agents-file MISSING "canonical project instructions" missing repository "create and review $root/AGENTS.md"
fi

# Two conventions below are declarable rather than mandatory. Both were reported
# as MISSING against repositories that had deliberately, and defensibly, chosen
# otherwise — and a checker that a mature repository must ignore is a checker
# nobody reads. Declaring the choice keeps it visible and intentional; the
# defaults are unchanged, so a repository that says nothing is checked as before.
policy_file="$root/.llmctx.json"
declared() { # declared <key> -> value, empty when unset or unreadable
  [[ -f "$policy_file" ]] || return 0
  # `has($k)`, not `.[$k] // empty`. jq's `//` yields its right-hand side when
  # the left is null OR false, so `"claudeImport": false` — the only value that
  # key is ever set to — read back as unset and the opt-out silently did
  # nothing. Distinguishing "absent" from "present and false" is the whole job.
  jq -r --arg k "$1" 'if has($k) then (.[$k] | tostring) else empty end' "$policy_file" 2>/dev/null
}

claude_import="$(declared claudeImport)"
if [[ "$claude_import" == "false" ]]; then
  add_finding claude-import OVERRIDE "CLAUDE.md imports AGENTS.md" "declined; AGENTS.md is tool-neutral" repo-policy ""
elif [[ ! -f "$root/CLAUDE.md" ]]; then
  add_finding claude-import MISSING "CLAUDE.md imports AGENTS.md" "CLAUDE.md missing" repository \
    "create CLAUDE.md with @AGENTS.md, or set \"claudeImport\": false in .llmctx.json"
elif grep -qE '^@(\./)?AGENTS\.md[[:space:]]*$' "$root/CLAUDE.md"; then
  add_finding claude-import OK "CLAUDE.md imports AGENTS.md" present repository ""
else
  add_finding claude-import MISSING "CLAUDE.md imports AGENTS.md" "import missing" repository "add @AGENTS.md to $root/CLAUDE.md"
fi

briefs="$(declared briefs)"
if [[ "$briefs" == "tracker" ]]; then
  # A brief that restates its ticket is a second copy to drift. A repository may
  # keep the narrative on the issue tracker instead; that is a position, not an
  # omission, so it is recorded rather than flagged.
  add_finding briefs OVERRIDE "briefs convention" "on the tracker, not in the tree" repo-policy ""
elif [[ -f "$root/docs/briefs/README.md" ]]; then
  add_finding briefs OK "briefs convention" "docs/briefs present" repository ""
else
  add_finding briefs MISSING "briefs convention" missing repository \
    "create and review $root/docs/briefs/README.md, or set \"briefs\": \"tracker\" in .llmctx.json"
fi

hooks_path="$(git -C "$root" config --get core.hooksPath || true)"
if [[ -n "$hooks_path" ]]; then
  add_finding git-hook UNKNOWN "agent-harness branch backstop" "managed by core.hooksPath=$hooks_path" git-local "integrate the branch check through that hook framework"

  # Do not stop here. Reporting only UNKNOWN and skipping the rest meant a
  # repository with core.hooksPath set and NO branch enforcement at all printed
  # "Result: compliant" — the one output nobody re-reads. Four repositories in
  # this estate are in that state today: each has its own guard, so each is safe
  # in practice, but none resolves llmctx policy, so .llmctx.json and
  # `git config llmctx.branchPolicy` are inert there. Silence made that
  # indistinguishable from working.
  hp_dir="$hooks_path"
  case "$hp_dir" in /*) ;; *) hp_dir="$root/$hp_dir" ;; esac
  if ! [[ -d "$hp_dir" ]]; then
    add_finding policy-enforcement MISSING "branch policy is enforced somewhere" \
      "core.hooksPath points at $hooks_path, which does not exist" git-local \
      "unset core.hooksPath, or create the directory it names"
  elif grep -rqlE 'llmctx-policy|llmctx_policy_resolve' "$hp_dir" 2>/dev/null; then
    add_finding policy-enforcement OK "branch policy is enforced somewhere" \
      "hooks in $hooks_path resolve llmctx policy" git-local ""
  elif grep -rqlE 'symbolic-ref|abbrev-ref|refusing to commit|protected branch' "$hp_dir" 2>/dev/null; then
    add_finding policy-enforcement UNKNOWN "branch policy is enforced somewhere" \
      "hooks in $hooks_path check a branch, but not via llmctx policy — .llmctx.json is inert here" git-local \
      "source bin/lib/policy.sh from that hook, or drop core.hooksPath and use pre-commit.local"
  else
    add_finding policy-enforcement MISSING "branch policy is enforced somewhere" \
      "no branch check found in $hooks_path" git-local \
      "add a branch check to that hook framework, or unset core.hooksPath"
  fi
else
  hooks_dir="$(git -C "$root" rev-parse --git-path hooks)"
  case "$hooks_dir" in /*) ;; *) hooks_dir="$root/$hooks_dir" ;; esac
  installed_hook="$hooks_dir/pre-commit"
  installed_policy="$hooks_dir/llmctx-policy.sh"
  remediation="$SRC/bin/install-git-hooks.sh $root"

  if [[ ! -f "$installed_hook" ]]; then
    add_finding git-hook MISSING "agent-harness branch backstop" missing git-hooks "$remediation"
  elif ! grep -q 'llmctx-hook' "$installed_hook"; then
    add_finding git-hook UNKNOWN "agent-harness branch backstop" "foreign pre-commit hook" git-hooks "$remediation"
  elif cmp "$SRC/bin/git-hooks/pre-commit" "$installed_hook" >/dev/null 2>&1; then
    add_finding git-hook OK "current agent-harness branch backstop" current git-hooks ""
  else
    add_finding git-hook STALE "current agent-harness branch backstop" stale git-hooks "$remediation"
  fi

  if [[ ! -f "$installed_policy" ]]; then
    add_finding git-policy-library MISSING "current policy resolver" missing git-hooks "$remediation"
  elif cmp "$SRC/bin/lib/policy.sh" "$installed_policy" >/dev/null 2>&1; then
    add_finding git-policy-library OK "current policy resolver" current git-hooks ""
  else
    add_finding git-policy-library STALE "current policy resolver" stale git-hooks "$remediation"
  fi
fi

if [[ "$output_json" -eq 1 ]]; then
  jq -s --arg repository "$root" --argjson compliant "$([[ "$failures" -eq 0 ]] && echo true || echo false)" \
    '{repository:$repository,compliant:$compliant,findings:.}' "$findings"
else
  printf 'Repository: %s\n' "$root"
  while IFS= read -r finding; do
    status="$(jq -r '.status' <<<"$finding")"
    id="$(jq -r '.id' <<<"$finding")"
    actual="$(jq -r '.actual' <<<"$finding")"
    source_name="$(jq -r '.source' <<<"$finding")"
    printf '%-8s %-24s %s [%s]\n' "$status" "$id" "$actual" "$source_name"
    remediation="$(jq -r '.remediation' <<<"$finding")"
    [[ -z "$remediation" ]] || printf '         fix: %s\n' "$remediation"
  done <"$findings"
  if [[ "$failures" -eq 0 ]]; then
    echo "Result: compliant"
  else
    echo "Result: $failures finding(s) require attention"
  fi
fi

[[ "$failures" -eq 0 ]]
