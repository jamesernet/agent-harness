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
#   force push          git push --force | -f (in any short cluster: -fu) |
#                       --force-with-lease | --force-if-includes | +<refspec>
#   history rewrite     git reset --hard | git filter-branch | git filter-repo |
#                       git reflog expire --expire=now | git gc --prune=now
#   branch deletion     git branch -D | --delete --force (either order) |
#                       git branch -M | -f <name> <start> (a forced move) |
#                       git update-ref -d | git push --delete | -d | --prune |
#                       --mirror | git push <remote> :<ref>
#   recursive delete    rm -r whose target resolves OUTSIDE the command's repo,
#                       or names / or a home outright (~, ~/, ~user, //, /., "$HOME"/).
#                       "Inside" includes every linked worktree of the same
#                       repository, and scratch roots are not outside: $TMPDIR
#                       (which is /tmp exactly where it is unset, as on Linux)
#                       and ~/.cache. A worktree-per-session flow cleans a
#                       sibling's node_modules, and a cache or a temp directory
#                       is where scratch goes; asking about those is how a
#                       guard earns its removal. Not a literal /tmp beside a set
#                       $TMPDIR: on macOS $TMPDIR is elsewhere, and a hook that
#                       calls two roots scratch cannot be told to call one.
#
# ...in any of the spellings a shell allows in front of the verb: `sudo`,
# `env K=V`, a bare `K=V` assignment, `command`, `exec`, `nohup`, `nice`,
# `time`, `timeout <n>`, `doas`, a leading path (`/bin/rm`), a quoted or
# backslash-escaped verb (`"git"`, `\git`, `git\ push`), git's global options
# between `git` and the subcommand
# (`-C <dir>`, `-c <k=v>`, `--no-pager`, `--git-dir=<d>`), as a later statement
# after `;` `&&` `||` `|`, after `then`/`do`/`else`/`{`/`!`, and INSIDE `$( )`
# or backticks — a subshell isolates directory and variables, not a push. The
# first version anchored every rule on `^git` and `^rm`, and `sudo rm -rf /`
# walked straight through it.
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
#   * `git push --dry-run`, in any spelling. It never contacts the remote, and
#     it is the careful way to preview a force push -- asking about it would
#     punish the caution the guidelines ask for.
#   * The body of a heredoc. `cat > notes.md <<'EOF'` followed by a line of
#     `git push --force` writes a file; the body lines are data and are not
#     read as statements.
#   * A command string handed to another interpreter: `eval "…"`, `bash -c "…"`,
#     `sh -c '…'`, `xargs rm -rf`, `find / -delete`. Judging those means
#     evaluating shell, which this deliberately never does. The limit is named
#     here so that an `eval` walking through is a known edge, not a surprise.
#   * A verb or a target held in a variable or a substitution: `$g push
#     --force`, `rm -rf "$BUILD"`, `rm -rf "$(pwd)/.."`. Only the two literal
#     spellings of home ($HOME, ${HOME}) are known by name; every other `$` is
#     "cannot tell", and a target this cannot tell about is NOT judged -- it
#     is neither called safe nor called dangerous. The first version resolved
#     the literal text against the repository and called it inside.
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
tool="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)"
# Only Bash. An Edit or a Write cannot force-push, and the matcher in
# claude/settings.json is re-checked here rather than trusted, for the reason
# branch-policy.sh gives: a hook that depends on its registration being right
# is a hook that silently stops working when the registration drifts.
[[ "$tool" == "Bash" ]] || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)"
[[ -n "$cmd" ]] || exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // "."' 2>/dev/null)"

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
# Resolved on its own, not through llmctx_policy_resolve: that one validates
# every key first and returns 1 on an unrelated typo, and this hook fails open
# on a non-zero return — so `branchPolicy: stirct` used to switch this gate off.
llmctx_policy_resolve_irreversible "$scope_dir" >/dev/null 2>&1 || exit 0
policy="$LLMCTX_IRREVERSIBLE_POLICY"
[[ "$policy" == "off" ]] && exit 0

repo="$(git -C "$scope_dir" rev-parse --show-toplevel 2>/dev/null || true)"
# Canonicalised before any comparison: `/var` and `/private/var` are the same
# directory on macOS, so an uncanonicalised prefix test against a
# rev-parse result is wrong in whichever direction the symlink was not followed.
[[ -z "$repo" ]] || repo="$(llmctx_target_canonical "$repo")"

# One statement per line, NOTHING removed, via the shared library — so
# `foo && git push --force` is its own statement, and so is the `git push
# --force` inside `echo "$(…)"`: a subshell isolates the working directory and
# variables, which is why the SCOPE resolver above strips substitutions, and it
# does not isolate the push, which is why the ACTION matcher must not.
statements="$(llmctx_target_action_statements "$cmd")"

# A word that is exactly this flag, not a substring of a longer argument.
has_flag() { # <statement> <flag>…
  local st="$1" f
  shift
  for f in "$@"; do
    printf '%s' " $st " | grep -qE "[[:space:]]${f//./\\.}[[:space:]]" && return 0
  done
  return 1
}

# A short-option cluster containing this letter: `-f`, `-fu`, `-uf`. git
# accepts clustered short flags and the first version matched only `-f` as a
# whole word, so `git push -fu origin main` was allowed.
has_short() { # <statement> <letter>
  printf '%s' " $1 " | grep -qE "[[:space:]]-[a-zA-Z]*$2[a-zA-Z]*[[:space:]]"
}

# What a shell allows in front of the verb. Every rule below anchors on this
# rather than on `^[[:space:]]*git` / `^[[:space:]]*rm`, because `sudo rm -rf /`
# — the single worst input this hook exists to catch — walked through the
# first version. Optional and repeatable: `sudo env A=1 /bin/rm`.
# A prefix command's flag may take a separate value (`sudo -u root`), so each
# flag may be followed by one non-flag word; the regex backtracks when that
# word turns out to be the verb.
prefix_re="^[[:space:]]*${LLMCTX_CMD_PREFIX_RE}([^[:space:]]*/)?"
# git's global options between `git` and the subcommand: the fragment the
# branch guard uses, defined beside the target resolver so both hooks see the
# same spelling (#79). `-C <dir>` is both scope and spelling.
git_re="${prefix_re}git[[:space:]]+${LLMCTX_GIT_GLOBAL_OPTS_RE:-}"
rm_re="${prefix_re}rm([[:space:]]|\$)"

# Is this statement `git <subcommand>` — the subcommand as the verb, behind any
# of the prefixes above? `echo git push --force` and `grep -r "reset --hard"`
# are not, because their verb is echo and grep.
is_git() { # <statement> <subcommand-alternation>
  printf '%s' "$1" | grep -qE "${git_re}($2)([[:space:]]|\$)"
}

# A dry run never contacts the remote. `--dry-run` anywhere, or `-n` in a short
# cluster AFTER the push word -- `sudo -n git push --force` is not a dry run.
# The tail is cut with a parameter expansion rather than matched with `.*`:
# BSD grep -E does not match `push[[:space:]].*[[:space:]]-n` against
# ` push -n -f `, measured, while the same cluster pattern alone matches.
push_is_dry_run() { # <statement>
  has_flag "$1" '--dry-run' && return 0
  has_short "${1#*push}" n
}

finding=""
detail=""

while IFS= read -r raw; do
  [[ -n "${raw//[[:space:]]/}" ]] || continue
  # Quotes and backslashes are spelling, not meaning: `"git" push`, `\git push`
  # and `git\ push` all run git. They are removed for matching the verb and
  # its flags; rm targets are read from the raw statement below and have their
  # own quote handling.
  st="$(printf '%s' "$raw" | tr -d '\\"'"'"'')"

  # --- git, by subcommand.
  if is_git "$st" push && ! push_is_dry_run "$st"; then
    # `+refspec` is the oldest spelling of a forced update, and a short cluster
    # (`-fu`) is how git actually accepts `-f` next to another flag.
    if has_flag "$st" '--force' '--force-with-lease' '--force-if-includes' '--force-with-lease=[^[:space:]]*' ||
      has_short "$st" f || printf '%s' " $st " | grep -qE '[[:space:]]\+[^[:space:]]+'; then
      finding="force push"
      detail="a force push overwrites published history; whatever it replaced is gone for anyone who had fetched it"
      break
    fi
    if has_flag "$st" '--delete' '--prune' '--mirror' || has_short "$st" d; then
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

  if is_git "$st" reset && has_flag "$st" '--hard'; then
    finding="hard reset"
    detail="a hard reset discards uncommitted work in the working tree and index, which nothing else holds a copy of"
    break
  fi

  if is_git "$st" 'filter-branch|filter-repo'; then
    finding="history rewrite"
    detail="this rewrites every commit it touches, so every existing commit id for them becomes wrong"
    break
  fi

  # The recovery path. A hard reset leaves its commits dangling and findable;
  # expiring the reflog now, or pruning unreachable objects now, is what makes
  # that loss permanent.
  if { is_git "$st" reflog && has_flag "$st" '--expire=now' '--expire-unreachable=now' '--expire=all' '--expire-unreachable=all'; } ||
    { is_git "$st" gc && has_flag "$st" '--prune=now' '--prune=all'; }; then
    finding="recovery pruning"
    detail="this removes the dangling commits and objects that a reset or a deleted branch could still be recovered from"
    break
  fi

  # Deleting a ref directly is a quieter spelling of `branch -D`, without even
  # git's unmerged-branch refusal in the way.
  if is_git "$st" update-ref && { has_flag "$st" '-d' '--delete' || has_short "$st" d; }; then
    finding="ref deletion"
    detail="update-ref -d deletes a branch or tag ref outright; -D would at least refuse an unmerged branch"
    break
  fi

  # A forced move of a branch: -M renames over an existing name, and
  # `branch -f <name> <start>` points the name somewhere else. The commits it
  # pointed to become unreachable, which is the same loss as -D.
  if is_git "$st" branch && ! has_flag "$st" '--remotes' && ! has_short "$st" r &&
    ! { has_flag "$st" '--delete' || has_short "$st" d || has_short "$st" D; } &&
    { has_short "$st" M || has_flag "$st" '--force' || has_short "$st" f; }; then
    finding="forced branch move"
    detail="-M or -f points a branch name at a different commit; whatever it pointed to is unreachable afterwards"
    break
  fi

  # `-D`, or `--delete` and `--force` in either order. A remote-tracking ref
  # (`-r`) is excluded: `git branch -rd origin/stale` is undone by `git fetch`,
  # and the first version flagged it with a message about unmerged branches,
  # which was neither what happened nor consistent with `-r -d` being allowed.
  if is_git "$st" branch && ! has_flag "$st" '--remotes' && ! has_short "$st" r &&
    { has_short "$st" D ||
      { { has_flag "$st" '--delete' || has_short "$st" d; } &&
        { has_flag "$st" '--force' || has_short "$st" f; }; }; }; then
    finding="force branch deletion"
    detail="-D deletes a branch git believes is unmerged; the guidelines reserve force-delete for an explicit request, and -d is the safe form"
    break
  fi

  # --- rm -r
  if printf '%s' "$st" | grep -qE "$rm_re" &&
    printf '%s' "$st" | grep -qE '[[:space:]]-[a-zA-Z]*[rR][a-zA-Z]*([[:space:]]|$)|[[:space:]]--recursive([[:space:]]|$)'; then
    # Everything after the verb that is not a flag is a target. The prefix and
    # the verb are removed first, so `/bin/rm` is not itself read as a target
    # outside the repository.
    targets="$(printf '%s' "$raw" |
      tr -d '\\' |
      sed -E "s#${rm_re}##" |
      tr ' \t' '\n\n' |
      sed -E -e '/^$/d' -e '/^-/d' -e "s/[\"']//g")"
    home_canonical="$(llmctx_target_canonical "$HOME")"
    while IFS= read -r t; do
      [[ -n "$t" ]] || continue
      t="$(llmctx_target_expand_home "$t")"
      # Normalised BEFORE the catastrophic test, not after it: `~/`, `//`,
      # `/.` and `/..` all name root or home, and the first version compared
      # the raw token, so `rm -rf ~` was stopped and `rm -rf ~/` was not.
      t="$(llmctx_target_strip_slashes "$t")"
      t="${t%/.}"
      [[ -n "$t" ]] || t="/"
      # `rm -rf "$HOME"` arrives as the literal four characters `$HOME`, not as
      # its value, because nothing here evaluates shell. The two spellings of
      # home that matter are recognised by name, after the slash stripping so
      # `$HOME/` is the same name; a path built from any other variable is not
      # guessable and falls through to the repository test, which is the same
      # conservative direction the rest of this takes.
      case "$t" in
        '$HOME' | '${HOME}') t="$HOME" ;;
        '$HOME/'*) t="$HOME/${t#\$HOME/}" ;;
        '${HOME}/'*) t="$HOME/${t#\$\{HOME\}/}" ;;
        '$'*) continue ;; # any other variable or substitution: cannot tell, so not judged
      esac
      # A `~user` that expand_home left alone is someone's home when that user
      # exists, and a directory literally named `~something` when not.
      # shellcheck disable=SC2154  # llmctx_target_tilde is set by lib/target.sh
      case "$t" in
        "$llmctx_target_tilde"*)
          tilde_user="${t#"$llmctx_target_tilde"}"
          tilde_user="${tilde_user%%/*}"
          if [[ -n "$tilde_user" ]] && id -u "$tilde_user" >/dev/null 2>&1; then
            t="/"
          fi
          ;;
      esac
      [[ "$t" != /* ]] || t="$(llmctx_target_canonical "$t")"
      # Catastrophic outright, repository or not.
      case "$t" in
        / | "$home_canonical")
          finding="recursive delete of a home or root path"
          detail="\"$t\" is not a path anything should be removing recursively"
          break 2
          ;;
      esac
      # Otherwise only judged against a repository, per the stated limit above.
      [[ -n "$repo" ]] || continue
      [[ "$t" == /* ]] || t="$scope_dir/$t"
      t="$(llmctx_target_canonical "$t")"
      inside=0
      case "$t" in
        "$repo" | "$repo"/*) inside=1 ;;
      esac
      # Every linked worktree of this repository is the same tree of work.
      if [[ "$inside" -eq 0 ]]; then
        while IFS= read -r wt; do
          [[ -n "$wt" ]] || continue
          wt="$(llmctx_target_canonical "$wt")"
          case "$t" in
            "$wt" | "$wt"/*)
              inside=1
              break
              ;;
          esac
        done < <(git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
      fi
      # Scratch roots are not outside: a path UNDER them, never the root itself.
      # $TMPDIR, not also a literal /tmp: the test suite points TMPDIR at a root
      # of its own, and on Linux its fixtures live under /tmp, which a literal
      # entry turned into scratch -- measured on CI as "outside repo: expected
      # ask, got allow".
      if [[ "$inside" -eq 0 ]]; then
        for scratch in "${TMPDIR:-/tmp}" "$HOME/.cache"; do
          [[ -d "$scratch" ]] || continue
          scratch="$(llmctx_target_canonical "$scratch")"
          case "$t" in
            "$scratch"/*)
              inside=1
              break
              ;;
          esac
        done
      fi
      case "$inside" in
        1) ;;
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
