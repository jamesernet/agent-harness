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

# A repository under a file-sync root is not a style question. iCloud created
# collision-duplicate files named "<name> 2" inside .git/refs of a checkout kept
# in ~/Documents; `git fetch` then failed with "fatal: bad object
# refs/heads/... 2" and the checkout reported a stale origin/main for days with
# no visible error. The same sync duplicated a tracked document, preserving a
# superseded copy beside the corrected one, and local Terraform state sat in the
# same tree.
#
# Checked per repository rather than in `doctor` because location is a property
# of a repository, and the estate audit runs `repo diff` on each one, so this
# covers both a single repository and the fleet.
#
# BOTH the working tree and the common Git directory are tested. For a linked
# worktree they are different places, and the refs that actually corrupt live in
# the common directory, so testing the checkout alone reported OK for a worktree
# whose shared .git sat in a synced tree — backwards from the incident above.
#
# Canonicalising never aborts the command. `cd` into a candidate can fail on an
# unreadable directory or a stalled network mount, and a failed command
# substitution under `set -e` took the whole of `repo diff` down with it,
# including every unrelated finding. An uncheckable candidate is skipped.
#
# ~/Documents and ~/Desktop are synced only when iCloud's Desktop & Documents
# option is on, and the CloudDocs mirror directory is what indicates that: the
# home directory keeps its ordinary path either way, so testing the path alone
# would report every Mac.
sync_canonical() { # <dir> -> resolved path, or the input when it cannot be read
  (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"
}

sync_declared="$(declared syncLocation)"
if [[ "$sync_declared" == "false" ]]; then
  # Declarable for the same reason claudeImport and briefs are: a checker a
  # mature repository must learn to ignore is a checker nobody reads. Moving the
  # repository is the fix; saying so out loud is the alternative.
  add_finding sync-location OVERRIDE "repository outside any file-sync root" \
    "declined; the owner accepts the sync risk for this repository" repo-policy ""
else
  home="${HOME:-}"
  sync_prefixes=()
  sync_labels=()
  if [[ -n "$home" ]]; then
    sync_prefixes+=("$home/Library/Mobile Documents") && sync_labels+=("iCloud Drive")
    sync_prefixes+=("$home/Library/CloudStorage") && sync_labels+=("a CloudStorage provider")
    # A second linked account renames these: Dropbox becomes "Dropbox (Personal)"
    # and "Dropbox (Business)", and OneDrive appends the organisation name as
    # "OneDrive - Example Org". Matching only the bare path missed all of those.
    #
    # The separator is matched rather than globbed open, because a bare trailing
    # `*` also matches a directory that merely STARTS with the vendor name:
    # ~/Dropbox-notes is an ordinary folder no sync client owns, and it was
    # reported CONFLICT with "synced by Dropbox-notes", failing `repo diff` for
    # a repository whose location is fine. Only the spellings a client actually
    # creates count: the bare name, " (" for Dropbox, " - " for OneDrive.
    for vendor in Dropbox OneDrive "Google Drive"; do
      for candidate_dir in "$home/$vendor" "$home/$vendor "\(*\) "$home/$vendor - "*; do
        [[ -d "$candidate_dir" ]] || continue
        sync_prefixes+=("$candidate_dir") && sync_labels+=("$(basename "$candidate_dir")")
      done
    done
    if [[ -d "$home/Library/Mobile Documents/com~apple~CloudDocs/Documents" ]]; then
      sync_prefixes+=("$home/Documents") && sync_labels+=("iCloud Desktop & Documents")
      sync_prefixes+=("$home/Desktop") && sync_labels+=("iCloud Desktop & Documents")
    fi
  fi

  common_dir="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null || printf '%s' "$root/.git")"
  case "$common_dir" in /*) ;; *) common_dir="$root/$common_dir" ;; esac
  # Parallel arrays, for the same reason sync_prefixes/sync_labels are: packing
  # "path|label" into one string and splitting on "|" truncates a path that
  # contains a literal pipe, so the finding named a directory that was not the
  # one tested.
  checked_targets=("$(sync_canonical "$root")")
  checked_whats=("working tree")
  git_state_dir="$(sync_canonical "$(dirname "$common_dir")")"
  if [[ "$git_state_dir" != "${checked_targets[0]}" ]]; then
    checked_targets+=("$git_state_dir") && checked_whats+=("shared Git directory")
  fi

  sync_hit=""
  entry=0
  while [[ "$entry" -lt "${#checked_targets[@]}" ]]; do
    target="${checked_targets[entry]}"
    what="${checked_whats[entry]}"
    index=0
    while [[ "$index" -lt "${#sync_prefixes[@]}" ]]; do
      prefix="$(sync_canonical "${sync_prefixes[index]}")"
      if [[ -d "$prefix" ]]; then
        case "$target/" in
          "$prefix"/*)
            sync_hit="$target is under $prefix, synced by ${sync_labels[index]} ($what)"
            break 2
            ;;
        esac
      fi
      index=$((index + 1))
    done
    entry=$((entry + 1))
  done

  if [[ -n "$sync_hit" ]]; then
    add_finding sync-location CONFLICT "repository outside any file-sync root" \
      "$sync_hit" filesystem \
      "move the repository outside that directory, for example under ~/repos/github.com/<org>/, then run git worktree repair; or set \"syncLocation\": false in .llmctx.json to accept the risk"
  else
    add_finding sync-location OK "repository outside any file-sync root" "not under a known sync root" filesystem ""
  fi
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
  elif grep -q 'scaffold-hook-shim' "$installed_hook"; then
    # project-scaffold's placeholder, asking to be replaced by the installer.
    # Reported identically to a husky hook, it looked like an integration a
    # person had to investigate; it is a one-command fix, so it is MISSING.
    add_finding git-hook MISSING "agent-harness branch backstop" "scaffold placeholder, not yet replaced" git-hooks "$remediation"
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
