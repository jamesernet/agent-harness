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
  # `|| true`: on a file that is not JSON, jq fails, and under set -e a failing
  # command substitution aborted the whole run before a single finding printed,
  # hiding the CONFLICT the resolver had just produced about that very file.
  jq -r --arg k "$1" 'if has($k) then (.[$k] | tostring) else empty end' "$policy_file" 2>/dev/null || true
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

# A repository may declare that it owns the hook seam: `"hooks": "repo-owned"` in
# .llmctx.json, on the precedent of briefs and claudeImport. The value is
# validated HERE, not in bin/lib/policy.sh, on purpose: the managed hooks source
# that resolver and skip their branch check when policy does not resolve, so a
# key only this checker reads must not be able to switch the guard off with a
# typo. A bad value is a CONFLICT of its own and then reads as undeclared.
# Ownership is honoured only over a directory core.hooksPath names and that
# exists, and it never changes what the evidence grep finds: a declared hook
# with no branch check is still MISSING. The OVERRIDE below claims ownership of
# the framework and nothing else; whether a branch check exists, and whether it
# consults llmctx policy, is the policy-enforcement row's to say.
hooks_owner="$(declared hooks)"
case "$hooks_owner" in
  "" | null) hooks_owner="" ;; # null reads as unset, as it does for briefs and claudeImport
  managed | repo-owned) ;;
  *)
    add_finding hooks-owner CONFLICT "hooks is managed or repo-owned" \
      "invalid hooks value in .llmctx.json: $hooks_owner" repo-policy \
      "set \"hooks\" to \"managed\" or \"repo-owned\" in .llmctx.json, or remove it"
    hooks_owner=""
    ;;
esac
common_dir_of() { # absolute, physical path of a repository's common git dir; empty if not one
  local d
  d="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 0
  case "$d" in /*) ;; *) d="$1/$d" ;; esac
  (cd "$d" 2>/dev/null && pwd -P) || printf '%s' "$d"
}

# Read once, with the scope where git has it, because the value is read from
# every scope and is often global, so a row that says "unset core.hooksPath"
# has to say where. --type=path expands a leading ~ the way git does when it
# runs these hooks; the plain read tested ~/hk as $root/~/hk and reported an
# existing directory as missing, the tilde class 9ef9b00 fixed elsewhere. It
# FAILS on a tilde it cannot expand (~nosuchuser/hk), and reading that as
# "unset" would grade .git/hooks, which git is not running; the raw value falls
# through to the directory test instead and is reported missing, as git itself
# will say. --show-scope needs git 2.26, so each read falls back to the plain
# one with the scope unknown rather than failing closed on an older git.
hooks_path=""
hooks_scope=""
if hooks_line="$(git -C "$root" config --show-scope --type=path --get core.hooksPath 2>/dev/null)" ||
  hooks_line="$(git -C "$root" config --show-scope --get core.hooksPath 2>/dev/null)"; then
  if [[ "$hooks_line" == *$'\t'* ]]; then
    hooks_scope="${hooks_line%%$'\t'*}"
    hooks_path="${hooks_line#*$'\t'}"
  else
    hooks_scope=unknown
    hooks_path="$hooks_line"
  fi
elif hooks_path="$(git -C "$root" config --type=path --get core.hooksPath 2>/dev/null)" ||
  hooks_path="$(git -C "$root" config --get core.hooksPath 2>/dev/null)"; then
  hooks_scope=unknown
else
  hooks_path=""
fi
if [[ -n "$hooks_path" ]]; then
  hp_where="core.hooksPath=$hooks_path ($hooks_scope config)"
  # The remediation unsets the value where it was set. `command` is a -c or
  # GIT_CONFIG_PARAMETERS override, which no `git config --<scope>` flag names.
  case "$hooks_scope" in
    command) hp_unset="drop the -c or GIT_CONFIG_PARAMETERS override that sets core.hooksPath" ;;
    unknown) hp_unset="unset core.hooksPath where it is set (git config --show-origin --get core.hooksPath names the file)" ;;
    *) hp_unset="git config --$hooks_scope --unset core.hooksPath" ;;
  esac
  hp_dir="$hooks_path"
  case "$hp_dir" in /*) ;; *) hp_dir="$root/$hp_dir" ;; esac
  if [[ -d "$hp_dir" && (! -r "$hp_dir" || ! -x "$hp_dir") ]]; then
    hp_state=unreadable
  elif [[ -d "$hp_dir" ]]; then
    hp_state=is-dir
  elif [[ -e "$hp_dir" ]]; then
    hp_state=is-file
  else
    hp_state=absent
  fi

  # The hook files that matter, found once: those that resolve llmctx policy,
  # and those that check a branch by other means. The policy-enforcement rows
  # read them, and so does the ownership test below.
  hp_llmctx_files=""
  hp_branch_files=""
  if [[ "$hp_state" == is-dir ]]; then
    hp_llmctx_files="$(grep -rlE 'llmctx-policy|llmctx_policy_resolve' "$hp_dir" 2>/dev/null || true)"
    hp_branch_files="$(grep -rlE 'symbolic-ref|abbrev-ref|refusing to commit|protected branch' "$hp_dir" 2>/dev/null || true)"
  fi

  # What the declaration amounts to, decided once for every row below.
  # repo-owned names a framework the repository TRACKS, and the test for that
  # is the repository's own index applied to the hook files themselves, not the
  # path and not any file: a global core.hooksPath that happens to check a
  # branch, an untracked or ignored directory under the root, .git/hooks itself
  # (which answers ls-files from the work tree's top, so the directory is also
  # asked whether it is inside the work tree), and a tracked README beside an
  # untracked hook all fail it, while a linked worktree pointing at the main
  # checkout's tracked hooks passes. An explicit `managed` over any
  # core.hooksPath is the mirror contradiction. Saying nothing stays UNKNOWN.
  hp_claim=none
  case "$hooks_owner" in
    managed) hp_claim=managed ;;
    repo-owned)
      hp_claim="repo-owned-$hp_state"
      if [[ "$hp_state" == is-dir ]]; then
        hp_claim=repo-owned-unguarded
        if [[ "$(common_dir_of "$hp_dir")" == "$(common_dir_of "$root")" ]] &&
          [[ "$(git -C "$hp_dir" rev-parse --is-inside-work-tree 2>/dev/null)" == true ]]; then
          while IFS= read -r hook_file; do
            [[ -n "$hook_file" ]] || continue
            if git -C "$hp_dir" ls-files --error-unmatch -- "$hook_file" >/dev/null 2>&1; then
              hp_claim=override
              break
            fi
          done <<<"$hp_llmctx_files"$'\n'"$hp_branch_files"
        fi
      fi
      ;;
  esac

  case "$hp_claim" in
    managed)
      add_finding hooks-owner CONFLICT "core.hooksPath is unset when hooks is managed" \
        "hooks=managed is declared, but $hp_where is set, so git runs that framework and not the managed backstop" "git-$hooks_scope" \
        "$hp_unset, or declare \"hooks\": \"repo-owned\" if that framework is the repository's own"
      add_finding git-hook UNKNOWN "agent-harness branch backstop" "declared managed, but $hp_where runs instead" "git-$hooks_scope" ""
      ;;
    override)
      add_finding git-hook OVERRIDE "agent-harness branch backstop" \
        "hook framework owned by core.hooksPath=$hooks_path, refreshed by the repository, not by this release" repo-policy ""
      ;;
    repo-owned-unguarded)
      add_finding hooks-owner CONFLICT "a repo-owned hook framework is tracked by this repository" \
        "hooks=repo-owned is declared, but $hp_where holds no tracked hook that checks a branch, so a clone of this repository would have no guard" "git-$hooks_scope" \
        "track the hook under core.hooksPath, or point it at the directory that holds one, or remove \"hooks\": \"repo-owned\" from .llmctx.json"
      add_finding git-hook UNKNOWN "agent-harness branch backstop" "declared repo-owned, but $hp_where holds no tracked branch check" "git-$hooks_scope" ""
      ;;
    repo-owned-is-file)
      add_finding git-hook UNKNOWN "agent-harness branch backstop" \
        "declared repo-owned, but $hp_where is a file, not a directory" "git-$hooks_scope" \
        "point core.hooksPath at the repository's hooks directory"
      ;;
    repo-owned-absent)
      add_finding git-hook UNKNOWN "agent-harness branch backstop" \
        "declared repo-owned, but $hp_where does not exist" "git-$hooks_scope" \
        "create the directory core.hooksPath names, or point it at the repository's hooks"
      ;;
    repo-owned-unreadable)
      add_finding git-hook UNKNOWN "agent-harness branch backstop" \
        "declared repo-owned, but $hp_where cannot be read by this user" "git-$hooks_scope" \
        "fix the directory's permissions"
      ;;
    *)
      add_finding git-hook UNKNOWN "agent-harness branch backstop" "managed by core.hooksPath=$hooks_path" "git-$hooks_scope" "integrate the branch check through that hook framework"
      ;;
  esac

  # Do not stop here. Reporting only UNKNOWN and skipping the rest meant a
  # repository with core.hooksPath set and NO branch enforcement at all printed
  # "Result: compliant" — the one output nobody re-reads. Four repositories in
  # this estate are in that state today: each has its own guard, so each is safe
  # in practice, but none resolves llmctx policy, so .llmctx.json and
  # `git config llmctx.branchPolicy` are inert there. Silence made that
  # indistinguishable from working.
  if [[ "$hp_state" == unreadable ]]; then
    add_finding policy-enforcement MISSING "branch policy is enforced somewhere" \
      "core.hooksPath points at $hooks_path, which cannot be read by this user" "git-$hooks_scope" \
      "fix the directory's permissions"
  elif [[ "$hp_state" == is-file ]]; then
    add_finding policy-enforcement MISSING "branch policy is enforced somewhere" \
      "core.hooksPath points at $hooks_path, which is a file, not a directory" "git-$hooks_scope" \
      "point core.hooksPath at a hooks directory, or $hp_unset"
  elif [[ "$hp_state" == absent ]]; then
    add_finding policy-enforcement MISSING "branch policy is enforced somewhere" \
      "core.hooksPath points at $hooks_path, which does not exist" "git-$hooks_scope" \
      "$hp_unset, or create the directory it names"
  elif [[ -n "$hp_llmctx_files" ]]; then
    add_finding policy-enforcement OK "branch policy is enforced somewhere" \
      "hooks in $hooks_path resolve llmctx policy" "git-$hooks_scope" ""
  elif [[ -n "$hp_branch_files" ]]; then
    if [[ "$hp_claim" == override ]]; then
      add_finding policy-enforcement OVERRIDE "branch policy is enforced somewhere" \
        "hooks in $hooks_path check a branch by the repository's own rules; .llmctx.json branch policy is inert here by declaration" repo-policy ""
    else
      add_finding policy-enforcement UNKNOWN "branch policy is enforced somewhere" \
        "hooks in $hooks_path check a branch, but not via llmctx policy — .llmctx.json is inert here" "git-$hooks_scope" \
        "source bin/lib/policy.sh from that hook, or $hp_unset and use pre-commit.local"
    fi
  else
    add_finding policy-enforcement MISSING "branch policy is enforced somewhere" \
      "no branch check found in $hooks_path" "git-$hooks_scope" \
      "add a branch check to that hook framework, or $hp_unset"
  fi
else
  # The declaration and this clone disagree: the repository says its own hooks
  # are the guard, and git is running the managed path below instead, because
  # core.hooksPath is local config that a fresh clone does not carry. Reporting
  # only the managed state here would tell the repository to install the
  # backstop it just declared it does not want.
  if [[ "$hooks_owner" == "repo-owned" ]]; then
    add_finding hooks-owner CONFLICT "core.hooksPath names the repository's hooks when hooks is repo-owned" \
      "hooks=repo-owned is declared, but core.hooksPath is unset in this clone; repo-owned names a hook framework the repository tracks and points core.hooksPath at, and git is running the hooks below instead" git-local \
      "set core.hooksPath to the repository's hooks directory, or remove \"hooks\": \"repo-owned\" from .llmctx.json"
  fi
  hooks_dir="$(git -C "$root" rev-parse --git-path hooks)"
  case "$hooks_dir" in /*) ;; *) hooks_dir="$root/$hooks_dir" ;; esac
  installed_hook="$hooks_dir/pre-commit"
  installed_policy="$hooks_dir/llmctx-policy.sh"
  remediation="$SRC/bin/install-git-hooks.sh $root"
  # With repo-owned declared, the hooks-owner CONFLICT above carries the one
  # fix; offering the installer beside it is a second, contradictory one.
  if [[ "$hooks_owner" == "repo-owned" ]]; then
    remediation=""
  fi

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
