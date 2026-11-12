#!/usr/bin/env bash
set -euo pipefail

# Claude Code PreToolUse hook: a routed path is edited on its own account.
#
# Installed by bin/build-adapters.sh into `hooks/` inside EVERY registered Claude
# account directory, like branch-policy.sh. It is symmetric and routes-only: a
# path with no route is nobody's business, so on a client account you can still
# edit a personal repo, and on the personal account a client tree is refused.
#
# ROUTES are machine state, so they live in global git config beside the account
# registry (llmctx.claudeAccount) and the skill bundle:
#
#   git config --global --add llmctx.accountRoute acme=~/repos/github.com/acme
#
# The account name must be a registered account (or `default`). Longest matching
# route wins, so a nested tree can belong to a different account than its parent.
#
# WHAT IT CATCHES: a shell that never loaded direnv — an editor-spawned terminal,
# a `claude` launched before `direnv allow`, a tmux pane predating the .envrc, or
# a repo-level .envrc missing `source_up_if_exists`, which shadows the parent
# silently and routes the session to the wrong login.
#
# WHAT IT CANNOT CATCH, stated plainly: quota is consumed by MODEL calls, and a
# PreToolUse hook runs after the first of those. This fails the session fast, at
# the first write, rather than preventing the first request. Early enough to stop
# a long run landing on the wrong account; not a billing boundary.
#
# ESCAPE HATCH: a sentinel file in the ACTIVE account's config dir, because this
# hook inherits Claude Code's environment and a variable set inside a tool call
# never reaches it. Deliberately not auto-expiring — a guard that restores itself
# mid-task reads as flapping, and a flapping guard gets deleted.
#
#   touch "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.allow-cross-account"   # suspend
#   rm    "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.allow-cross-account"   # restore
#
# KNOWN LIMIT: paths are compared after resolving symlinks and `..` through the
# deepest ancestor that exists, so a routed tree reached through a symlink or a
# relative path is still caught. Case is not folded: on a case-insensitive
# volume, `~/Repos/acme` and `~/repos/acme` are one directory and this hook
# treats them as two. Route the spelling your shell actually uses.
#
# Fails OPEN on any error, matching branch-policy.sh.
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_LIB="$SCRIPT_DIR/llmctx-target.sh"
[[ -f "$TARGET_LIB" ]] || TARGET_LIB="$SCRIPT_DIR/../lib/target.sh"
[[ -f "$TARGET_LIB" ]] || exit 0
# shellcheck source=../lib/target.sh
source "$TARGET_LIB"

# Tilde expansion has one implementation, in the library. It is used here for
# route paths and config directories as well as for a command target, so it is
# wrapped under the shorter local name rather than spelled out at each of the
# seven call sites.
expand_home() { llmctx_target_expand_home "$1"; }
# Path canonicalisation has one implementation, in the library, for the same
# reason tilde expansion does: a third consumer now needs it.
canonical() { llmctx_target_canonical "$1"; }

# No routes, no work. This is the common case on a machine without clients, and
# it must cost nothing.
routes="$(git config --global --get-all llmctx.accountRoute 2>/dev/null || true)"
[[ -n "$routes" ]] || exit 0

active_dir="$(canonical "$(expand_home "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")")"
home_claude="$(canonical "$HOME/.claude")"
[[ -e "$active_dir/.allow-cross-account" ]] && exit 0

# Which account is active: the registry maps name=dir; $HOME/.claude is always
# `default`, registered or not.
active_name=""
[[ "$active_dir" == "$home_claude" ]] && active_name="default"
if [[ -z "$active_name" ]]; then
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    name="${entry%%=*}"
    dir="$(canonical "$(expand_home "${entry#*=}")")"
    [[ "$dir" == "$active_dir" ]] && active_name="$name" && break
  done < <(git config --global --get-all llmctx.claudeAccount 2>/dev/null || true)
fi
# An unregistered config dir cannot be judged; say nothing rather than guess.
[[ -n "$active_name" ]] || exit 0

input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // ""')"
case "$tool" in
  Edit | Write | NotebookEdit | Bash) ;;
  *) exit 0 ;;
esac

# Judge the TARGET, not the session cwd, for the reason branch-policy.sh gives.
# For Bash that means the directory a `git -C` names or the last
# statement-initial `cd` lands in, the way branch-policy.sh resolves it; the
# session cwd is the fallback. Judging Bash by cwd alone let `cd <client> &&
# edit` pass from a personal directory and denied `direnv allow` — the very
# fix the denial prints — from inside the client tree.
cwd="$(printf '%s' "$input" | jq -r '.cwd // "."')"
target="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')"
if [[ -z "$target" && "$tool" == "Bash" ]]; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
  # The remediation this hook prints is `touch <config-dir>/.allow-cross-account`,
  # and the session that needs it is usually standing in the routed tree. A
  # command that names the sentinel is operating on the account, not the tree.
  case "$cmd" in
    *.allow-cross-account*) exit 0 ;;
  esac
  # Which directory the command acts on is bin/lib/target.sh's job, shared with
  # branch-policy.sh so the two can no longer drift. An unresolvable `$VAR`
  # yields nothing there, so this falls back to the payload cwd rather than
  # matching a route on the strength of a path nobody wrote.
  target="$(llmctx_target_from_command "$cmd")"
fi
[[ -n "$target" ]] || target="$cwd"
target="$(expand_home "$target")"
[[ "$target" == /* ]] || target="$cwd/$target"
target="$(canonical "$target")"

# Anything inside the active account's own config directory is that account's
# business — including the sentinel file this hook tells you to touch.
case "$target" in
  "$active_dir" | "$active_dir"/*) exit 0 ;;
esac

# Longest matching route wins.
route_name=""
route_path=""
while IFS= read -r entry; do
  [[ -n "$entry" ]] || continue
  name="${entry%%=*}"
  path="$(expand_home "${entry#*=}")"
  [[ "$path" == /* ]] || continue
  path="$(canonical "$path")"
  [[ -n "$path" ]] || continue
  case "$target" in
    "$path" | "$path"/*)
      if [[ "${#path}" -gt "${#route_path}" ]]; then
        route_name="$name"
        route_path="$path"
      fi
      ;;
  esac
done <<<"$routes"
[[ -n "$route_name" ]] || exit 0
[[ "$route_name" != "$active_name" ]] || exit 0

# A route to an account this machine has not registered is a misconfiguration
# doctor reports; enforcing it here would deny with directions to a directory
# that does not exist. Fail open instead.
expected_dir=""
if [[ "$route_name" == "default" ]]; then
  expected_dir="$HOME/.claude"
else
  while IFS= read -r entry; do
    [[ "${entry%%=*}" == "$route_name" ]] && expected_dir="$(expand_home "${entry#*=}")" && break
  done < <(git config --global --get-all llmctx.claudeAccount 2>/dev/null || true)
fi
[[ -n "$expected_dir" ]] || exit 0

reason="This path is routed to the \"$route_name\" Claude account, but the session is on \"$active_name\".

  target             $target
  route              $route_path  ->  $route_name
  CLAUDE_CONFIG_DIR  ${CLAUDE_CONFIG_DIR:-<unset>}   (expected $expected_dir)

The likely cause is a shell that never loaded direnv. From a terminal OUTSIDE this session:
  cd \"$route_path\" && direnv allow .
  # then start a new session there: claude    and confirm with /status

If a repo under that path has its own .envrc, it needs 'source_up_if_exists' as its
first line, or it shadows the parent entirely and this keeps firing.

To work here on the \"$active_name\" account deliberately, suspend the guard:
  touch \"$active_dir/.allow-cross-account\"    # then rm it when done"

jq -n --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
