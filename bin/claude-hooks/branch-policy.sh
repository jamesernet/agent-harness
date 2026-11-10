#!/usr/bin/env bash
set -euo pipefail

# Claude Code PreToolUse hook: "branch before you build".
#
# Installed by bin/build-adapters.sh into `hooks/` inside EVERY registered Claude
# account directory, and referenced from claude/settings.json through the
# {{CLAUDE_CONFIG_DIR}} placeholder. This header used to name ~/.claude/hooks
# specifically, which is wrong in every copy but one — the whole point of the
# accounts model is that each config dir gets its own, so no account depends on
# another's directory surviving. Lives here as a real script rather than
# an escaped one-liner inside settings.json so it can be read, shellcheck'd and
# tested — the previous inline version was four levels of JSON escaping deep,
# which made the most security-relevant code in the repo the only code the
# linter could not see.
#
# POLICY, not enforcement. The rule is documented in
# global/behavioral-guidelines.md §5; this hook is one of several backstops, and
# how hard it pushes is a per-repo decision:
#
#   git config llmctx.branchPolicy off      silent; no check at all
#   git config llmctx.branchPolicy remind   remind once per session, then allow   [default]
#   git config llmctx.branchPolicy ask      confirm on every edit/commit
#   git config llmctx.branchPolicy deny     block outright
#
# Repo-local config beats global automatically (git config precedence), so:
#   git config --global llmctx.branchPolicy remind   # your default everywhere
#   git config llmctx.branchPolicy deny              # strict, in this repo only
#
# Why `remind` is the default rather than `deny`: a hard block on main is right
# for a client repo with a real review process, and wrong for a personal repo
# that legitimately has one branch. A guard that is wrong half the time gets
# disabled entirely, and then it protects nothing. Defaulting to a reminder
# keeps the norm visible everywhere while leaving `deny` available where it
# genuinely applies. A committed client profile defaults to `deny`.
#
# Which branches count as protected is configurable too:
#   git config llmctx.protectedBranches "main master release"

# Any unexpected failure must ALLOW, never block. A broken guard that wedges
# every edit is worse than no guard: it trains you to remove it.
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"

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

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""')"

# Only mutating tools are in scope. This deliberately re-checks the tool name
# rather than trusting the `matcher` in settings.json to be correct: matchers
# get widened over time, and a guard that blocks Read the moment someone adds a
# tool to that regex is a guard that gets deleted.
case "$tool" in
  Edit | Write | NotebookEdit | Bash) ;;
  *) exit 0 ;;
esac

if [[ "$tool" == "Bash" ]]; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
fi

# SCOPE BY WHAT IS BEING CHANGED, NOT BY WHERE THE SESSION HAPPENS TO STAND.
#
# This used to resolve the repository from the process cwd and judge that
# repository's branch, whatever the tool was actually touching. Two false
# denials followed, both hard blocks under `deny`, and neither action broke the
# rule:
#
#   - an Edit to a file in /tmp, which is not in any git repository at all
#   - `git push` to a DIFFERENT repository, from a feature branch
#
# both denied because an unrelated repository the session was cd'ed into had
# main checked out. That is how a guard earns its bypass — and the bypass
# disables the guard you actually wanted.
#
# So resolve the repository from the target: the file being written, or the
# directory a `git -C` names. Falling back to cwd is right for a bare `git
# commit`, which really does act on the session's repository.
scope_dir=""
case "$tool" in
  Edit | Write | NotebookEdit)
    target="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')"
    if [[ -n "$target" ]]; then
      [[ "$target" == /* ]] || target="$(printf '%s' "$input" | jq -r '.cwd // "."')/$target"
      # A new file's parent may not exist yet — walk up to the deepest ancestor
      # that does, so `git -C` has somewhere real to stand.
      scope_dir="$(dirname "$target")"
      while [[ ! -d "$scope_dir" && "$scope_dir" != "/" && "$scope_dir" != "." ]]; do
        scope_dir="$(dirname "$scope_dir")"
      done
    fi
    ;;
  Bash)
    # Which directory the command acts on is bin/lib/target.sh's job: a
    # `git -C`, else the last statement-initial `cd`, with one level of
    # same-command variable lookup. The reasoning, and the measured bugs behind
    # the current form, live there with the code they explain.
    cd_dir="$(llmctx_target_from_command "$cmd")"

    # A relative cd is relative to the session, so resolve it from there. The
    # library returns what was written and leaves this to the caller, because
    # the payload cwd is the only cwd this hook may trust.
    case "$cd_dir" in
      "" | /*) ;;
      *) cd_dir="$(printf '%s' "$input" | jq -r '.cwd // "."')/$cd_dir" ;;
    esac

    # This hook needs somewhere real for `git -C` to stand, so a path that does
    # not exist falls through to the session cwd. account-guard.sh wants the
    # opposite and canonicalises instead; that difference is why the library
    # does not decide existence.
    [[ -n "$cd_dir" && -d "$cd_dir" ]] && scope_dir="$cd_dir"
    ;;
esac

# Fall back to the cwd the HOOK PAYLOAD reports, not the process's own. They are
# normally the same, but depending on the process cwd made this untestable: the
# suite runs the hook from wherever the runner stands, so a `git commit` case
# silently resolved against the test repository instead of the session's and
# passed while doing nothing. Reading it from the payload makes the input
# complete, which is the only way a fixture can exercise it.
[[ -n "$scope_dir" ]] || scope_dir="$(printf '%s' "$input" | jq -r '.cwd // "."')"
[[ -d "$scope_dir" ]] || scope_dir="."

repo="$(git -C "$scope_dir" rev-parse --show-toplevel 2>/dev/null || true)"
# Not a git repository — a scratch file, a plan, global config. None of our
# business, and previously the single most common false denial.
[[ -n "$repo" ]] || exit 0
# Invalid policy must not wedge every edit. doctor/repo diff reports the error.
llmctx_policy_resolve "$repo" || exit 0
policy="$LLMCTX_BRANCH_POLICY"
[[ "$policy" == "off" ]] && exit 0

# symbolic-ref, NOT `rev-parse --abbrev-ref HEAD`. On an unborn branch — a repo
# freshly `git init`ed, before its first commit — rev-parse reports the literal
# string "HEAD", so a brand new `main` reads as unprotected and the very first
# commit of a repo sails past the guard. symbolic-ref resolves it correctly.
# It exits non-zero on a detached HEAD, which is not a protected branch anyway.
branch="$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || true)"
[[ -n "$branch" ]] || exit 0 # not a git repo, or detached HEAD

protected="$LLMCTX_PROTECTED_BRANCHES"
is_protected=0
for b in $protected; do
  [[ "$branch" == "$b" ]] && is_protected=1 && break
done
[[ "$is_protected" -eq 1 ]] || exit 0

# A merge, rebase, cherry-pick or bisect in progress legitimately edits files on
# the protected branch — that is what resolving a conflict IS. Worse, the advice
# this hook gives is actively wrong mid-operation: branching now would strand the
# in-flight merge. Stay out of the way until it finishes.
# `--absolute-git-dir`, not `--git-path .`. The latter answers RELATIVE to the
# process cwd — in a primary checkout it returns the literal `.git/.` — while
# the `-e` tests below run from wherever the session happens to stand, not from
# `$repo`. The exemption therefore applied only when the hook's own cwd was
# already the repository root: a session sitting in a sibling worktree, which is
# the normal arrangement here, got denied mid-merge on the very branch the merge
# has to happen on. Absolute also resolves to the PER-WORKTREE git dir, which is
# where MERGE_HEAD and the rebase directories actually live.
git_dir="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null || echo "$repo/.git")"
for state in MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-merge rebase-apply; do
  [[ -e "$git_dir/$state" ]] && exit 0
done

# For Bash, only git commit/push matter. Everything else on a protected branch
# is fine — reading, building, running tests, and `git checkout -b` itself,
# which must not be blocked or the suggested fix would be unreachable.
if [[ "$tool" == "Bash" ]]; then
  # Match `git commit`/`git push` only where a command can actually START:
  # beginning of string, or after ; && || | & or a newline. Plain substring
  # matching also fired on `echo "run git commit first"`, a heredoc mentioning
  # it, or `grep -r "git push" .` — and under `deny` every one of those false
  # positives is a hard block on an innocent command, which is how a guard
  # earns its removal. Optional leading `sudo`/`env`; allows `cd x && git commit`.
  if ! printf '%s' "$cmd" |
    grep -qE '(^|[;&|]|&&|\|\||[[:space:]]&|^[[:space:]]*)[[:space:]]*(sudo[[:space:]]+|env[[:space:]]+[^[:space:]]+=[^[:space:]]*[[:space:]]+)*git[[:space:]]+(commit|push)\b'; then
    exit 0
  fi

  # A push that NAMES an unprotected branch is not a trunk violation — pushing
  # `feature/x` from a checkout that happens to sit on main is the normal way to
  # publish work, and denying it was the second false block this hook produced.
  # Only an explicit refspec counts: a bare `git push` on a protected branch
  # still pushes the protected branch, and is still caught.
  if printf '%s' "$cmd" | grep -qE 'git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?push\b'; then
    pushed_ref="$(printf '%s' "$cmd" |
      sed -n 's/.*push[[:space:]]\{1,\}\(-[^[:space:]]*[[:space:]]\{1,\}\)*[^[:space:]-][^[:space:]]*[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\2/p' | head -1)"
    pushed_ref="${pushed_ref#*:}" # src:dst — the destination is what lands
    if [[ -n "$pushed_ref" ]]; then
      ref_protected=0
      for b in $LLMCTX_PROTECTED_BRANCHES; do
        [[ "$pushed_ref" == "$b" || "$pushed_ref" == "refs/heads/$b" ]] && ref_protected=1 && break
      done
      [[ "$ref_protected" -eq 1 ]] || exit 0
    fi
  fi
fi

# `remind`: fire once per (session, repo), then get out of the way. Keyed on the
# session_id Claude Code passes in, so a new session reminds again but a long
# one does not nag on every edit.
if [[ "$policy" == "remind" ]]; then
  session="$(printf '%s' "$input" | jq -r '.session_id // "nosession"')"
  marker_dir="${TMPDIR:-/tmp}/claude-branch-policy"
  marker="$marker_dir/$(printf '%s|%s' "$session" "$repo" | shasum | cut -d' ' -f1)"
  mkdir -p "$marker_dir"
  # One marker per (session, repo), and sessions are never revisited — so
  # without this they accumulate indefinitely. Cheap, and keeps the hook from
  # slowly littering a directory nobody thinks to look at.
  find "$marker_dir" -type f -mtime +7 -delete 2>/dev/null || true
  [[ -e "$marker" ]] && exit 0
  : >"$marker"
fi

decision="ask"
[[ "$policy" == "deny" ]] && decision="deny"

# NAME THE CHECKOUT, NOT JUST THE BRANCH.
#
# The scoping above judges the checkout that owns the file or command, which
# under a worktree-per-session flow is routinely NOT the directory the session
# is standing in. A denial reading only `On protected branch "main"`, delivered
# to a session that can see it is on a feature branch, reads as a broken guard —
# and the documented reaction to a broken guard is the `off` line this very
# message suggests, which disables it for the whole repository. Saying which
# HEAD was read makes the denial checkable instead of unbelievable.
session_repo="$(git -C "$(printf '%s' "$input" | jq -r '.cwd // "."')" \
  rev-parse --show-toplevel 2>/dev/null || true)"
elsewhere=""
[[ -n "$session_repo" && "$session_repo" == "$repo" ]] ||
  elsewhere="
That branch was read from the checkout above, which is where this change lands.
It is not this session's directory${session_repo:+ ($session_repo)}.
"

reason="On protected branch \"$branch\" in $repo. The convention (behavioral-guidelines §5) is to branch first:

  git checkout -b feature/<short-description>
$elsewhere
If that checkout legitimately works on $branch, relax it there:
  git -C \"$repo\" config llmctx.branchPolicy off"

jq -n --arg d "$decision" --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
