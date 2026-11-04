#!/usr/bin/env bash
set -euo pipefail

# Claude Code PreToolUse hook: an action that cannot be undone stops first.
#
# behavioural-guidelines §6 names six irreversible actions and a push-or-PR
# rule, and until this hook none of the seven had any enforcement. The branch
# guard already parsed the Bash command string in detail and looked only for
# `git commit` and `git push`, judging the BRANCH; this judges the ACTION.
#
# SECOND TENANT ON THE SAME LADDER. It reuses llmctx_policy_resolve, so
# `irreversiblePolicy` resolves through the identical four tiers as
# `branchPolicy` — repo-local git config, committed .llmctx.json, global git
# config, built-in — and `llmctx explain irreversiblePolicy` reports which one
# answered. One tenant on a seam is a hypothesis; this is what makes it a seam.
#
# WHAT IT JUDGES, and nothing else:
#
#   force push          git push --force | -f | --force-with-lease | --force-if-includes
#   history rewrite     git reset --hard | git filter-branch | git filter-repo
#   branch deletion     git branch -D | git push --delete | git push <remote> :<ref>
#   recursive delete    rm -r whose target resolves OUTSIDE the command's repo,
#                       or names /, $HOME or ~ outright
#
# WHAT IT DELIBERATELY DOES NOT JUDGE, because a guard that is wrong half the
# time gets switched off and then protects nothing (guidelines §5 says exactly
# this about the branch policy):
#
#   * Database drops and migrations against a non-local environment. §6 names
#     both. Neither is recognisable from a command string without guessing at
#     which connection string points where, and the false positives would land
#     on ordinary local work.
#   * `git rebase` and `git commit --amend`. Both rewrite history and both are
#     the normal way to tidy a feature branch before review. The guidelines'
#     concern is rewriting what has been published, which this cannot see.
#   * A push or a pull request made without being asked. That is a §6 rule with
#     no mechanism here: `gh pr create` is a different tool invocation, and the
#     stage for a push rule is a pre-push hook, which this repository does not
#     have.
#   * `rm -r` inside the repository. Deleting your own build output is ordinary
#     work. The line is reaching outside the tree you are working in.
#
# STATED LIMIT: when the command's directory is not in a git repository, only
# the catastrophic absolute targets are judged. There is no "my work area" to be
# outside of, and asking about every recursive delete in a scratch directory is
# how a guard earns its own removal.
#
# Fails OPEN on any error, matching branch-policy.sh and account-guard.sh: a
# broken guard that wedges every command is worse than no guard, because it
# trains you to remove it.
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_LIB="$SCRIPT_DIR/llmctx-policy.sh"
[[ -f "$POLICY_LIB" ]] || POLICY_LIB="$SCRIPT_DIR/../lib/policy.sh"
[[ -f "$POLICY_LIB" ]] || exit 0
# shellcheck source=../lib/policy.sh
source "$POLICY_LIB"

TARGET_LIB="$SCRIPT_DIR/llmctx-target.sh"
[[ -f "$TARGET_LIB" ]] || TARGET_LIB="$SCRIPT_DIR/../lib/target.sh"
[[ -f "$TARGET_LIB" ]] || exit 0
# shellcheck source=../lib/target.sh
source "$TARGET_LIB"

input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // ""')"
# Only Bash. An Edit or a Write cannot force-push, and the matcher in
# claude/settings.json is re-checked here rather than trusted, for the reason
# branch-policy.sh gives: a hook that depends on its registration being right
# is a hook that silently stops working when the registration drifts.
[[ "$tool" == "Bash" ]] || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
[[ -n "$cmd" ]] || exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // "."')"

# Judge the TARGET's repository, not the session's, exactly as the other two
# hooks do. bin/lib/target.sh is the shared resolver.
scope_dir="$(llmctx_target_from_command "$cmd")"
case "$scope_dir" in
  "" | /*) ;;
  *) scope_dir="$cwd/$scope_dir" ;;
esac
[[ -n "$scope_dir" && -d "$scope_dir" ]] || scope_dir="$cwd"
[[ -d "$scope_dir" ]] || scope_dir="."

# The policy resolves even outside a repository: `git -C <dir> config --local`
# simply fails there, so resolution falls through to global config and the
# built-in. That is what lets the catastrophic-target rule below apply anywhere.
llmctx_policy_resolve "$scope_dir" >/dev/null 2>&1 || exit 0
policy="$LLMCTX_IRREVERSIBLE_POLICY"
[[ "$policy" == "off" ]] && exit 0

repo="$(git -C "$scope_dir" rev-parse --show-toplevel 2>/dev/null || true)"
# Canonicalised before any comparison: `/var` and `/private/var` are the same
# directory on macOS, so an uncanonicalised prefix test against a
# rev-parse result is wrong in whichever direction the symlink was not followed.
[[ -z "$repo" ]] || repo="$(llmctx_target_canonical "$repo")"

# One statement per line, command substitutions removed, via the shared library
# — so `foo && git push --force` is seen as its own statement and a `--force`
# inside "$(...)" is not read as one.
statements="$(llmctx_target_statements "$cmd")"

# A word that is exactly this flag, not a substring of a longer argument.
has_flag() { # <statement> <flag>…
  local st="$1" f
  shift
  for f in "$@"; do
    printf '%s' " $st " | grep -qE "[[:space:]]${f//./\\.}[[:space:]]" && return 0
  done
  return 1
}

finding=""
detail=""

while IFS= read -r st; do
  [[ -n "${st//[[:space:]]/}" ]] || continue

  # --- git, by subcommand. The subcommand must be the statement's verb, so
  #     `echo git push --force` and `grep -r "reset --hard"` are not matched.
  if printf '%s' "$st" | grep -qE '^[[:space:]]*git([[:space:]]+-[^[:space:]]+|[[:space:]]+-C[[:space:]]+[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)'; then
    if has_flag "$st" '--force' '-f' '--force-with-lease' '--force-if-includes' '--force-with-lease=[^[:space:]]*'; then
      finding="force push"
      detail="a force push overwrites published history; whatever it replaced is gone for anyone who had fetched it"
      break
    fi
    if has_flag "$st" '--delete' '-d'; then
      finding="remote branch deletion"
      detail="this deletes a branch on the remote, which the guidelines say never happens without an explicit request"
      break
    fi
    # A colon refspec with an empty left side pushes nothing to the ref, which
    # is the older spelling of a delete.
    if printf '%s' "$st" | grep -qE '[[:space:]]:[^[:space:]]+'; then
      finding="remote branch deletion"
      detail="a refspec with an empty left side (:ref) deletes that ref on the remote"
      break
    fi
  fi

  if printf '%s' "$st" | grep -qE '^[[:space:]]*git([[:space:]]+-C[[:space:]]+[^[:space:]]+)*[[:space:]]+reset([[:space:]]|$)' &&
    has_flag "$st" '--hard'; then
    finding="hard reset"
    detail="a hard reset discards uncommitted work in the working tree and index, which nothing else holds a copy of"
    break
  fi

  if printf '%s' "$st" | grep -qE '^[[:space:]]*git([[:space:]]+-C[[:space:]]+[^[:space:]]+)*[[:space:]]+(filter-branch|filter-repo)([[:space:]]|$)'; then
    finding="history rewrite"
    detail="this rewrites every commit it touches, so every existing commit id for them becomes wrong"
    break
  fi

  if printf '%s' "$st" | grep -qE '^[[:space:]]*git([[:space:]]+-C[[:space:]]+[^[:space:]]+)*[[:space:]]+branch([[:space:]]|$)' &&
    has_flag "$st" '-D' '--delete[[:space:]]+--force' '-rd'; then
    finding="force branch deletion"
    detail="-D deletes a branch git believes is unmerged; the guidelines reserve force-delete for an explicit request, and -d is the safe form"
    break
  fi

  # --- rm -r
  if printf '%s' "$st" | grep -qE '^[[:space:]]*rm([[:space:]]|$)' &&
    printf '%s' "$st" | grep -qE '[[:space:]]-[a-zA-Z]*[rR][a-zA-Z]*([[:space:]]|$)|[[:space:]]--recursive([[:space:]]|$)'; then
    # Everything that is not the command and not a flag is a target.
    targets="$(printf '%s' "$st" |
      tr ' \t' '\n\n' |
      sed -E -e '/^$/d' -e '/^rm$/d' -e '/^-/d' -e "s/^[\"']//" -e "s/[\"']\$//")"
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      t="$(llmctx_target_expand_home "$t")"
      # `rm -rf "$HOME"` arrives as the literal four characters `$HOME`, not as
      # its value, because nothing here evaluates shell. The two spellings of
      # home that matter are recognised by name; a path built from any other
      # variable is not guessable and falls through to the repository test,
      # which is the same conservative direction the rest of this takes.
      case "$t" in
        '$HOME' | '${HOME}') t="$HOME" ;;
      esac
      # Catastrophic outright, repository or not.
      case "$t" in
        / | "$HOME" | '~')
          finding="recursive delete of a home or root path"
          detail="\"$t\" is not a path anything should be removing recursively"
          break 2
          ;;
      esac
      # Otherwise only judged against a repository, per the stated limit above.
      [[ -n "$repo" ]] || continue
      [[ "$t" == /* ]] || t="$scope_dir/$t"
      t="$(llmctx_target_canonical "$t")"
      case "$t" in
        "$repo" | "$repo"/*) ;;
        *)
          finding="recursive delete outside the repository"
          detail="\"$t\" is outside $repo, which is the tree this command is working in"
          break 2
          ;;
      esac
    done <<<"$targets"
  fi
done <<<"$statements"

[[ -n "$finding" ]] || exit 0

# `remind` is honestly degraded to `ask`, the way bin/git-hooks/pre-commit
# degrades `ask` to a warning because it cannot prompt. Reminding once that a
# destructive command is destructive and then allowing every one that follows
# protects nothing, and the ladder is shared, so the value stays spellable
# rather than being rejected.
decision="ask"
[[ "$policy" == "deny" ]] && decision="deny"

reason="$finding: $detail

policy: irreversiblePolicy = $policy (source: $LLMCTX_IRREVERSIBLE_POLICY_SOURCE)"
if [[ -n "$repo" ]]; then
  reason="$reason
repository: $repo"
fi
reason="$reason

If this is what you meant, say so and run it again — the confirmation is the point.
To change the policy here:  git config llmctx.irreversiblePolicy off|ask|deny"

jq -nc --arg r "$reason" --arg d "$decision" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
