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
# routing-tripwire.sh says the same thing at session start, before the first
# prompt, through the same library; a SessionStart hook cannot refuse anything,
# so this hook remains the gate.
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
# Routes and the account registry are read through one library, shared with the
# SessionStart tripwire (routing-tripwire.sh), so the two cannot drift apart.
ROUTES_LIB="$SCRIPT_DIR/llmctx-routes.sh"
[[ -f "$ROUTES_LIB" ]] || ROUTES_LIB="$SCRIPT_DIR/../lib/routes.sh"
[[ -f "$ROUTES_LIB" ]] || exit 0
# shellcheck source=../lib/routes.sh
source "$ROUTES_LIB"

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
llmctx_routes_load
[[ -n "$LLMCTX_ROUTES" ]] || exit 0

# The sentinel is judged again inside the library; it is read here first so a
# suspended guard never pays for jq.
active_dir="$(llmctx_routes_active_dir)"
[[ -e "$active_dir/.allow-cross-account" ]] && exit 0
# An unregistered config dir cannot be judged. The library says so too, but
# said here first the payload is never parsed for it, as before the extraction.
[[ -n "$(llmctx_routes_active_account)" ]] || exit 0

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

# Everything that decides whether this write belongs to another account is one
# library call, shared with routing-tripwire.sh. Silence is "cannot tell" or
# "nothing to say"; the library's header lists which cases, and every one of
# them fails open.
verdict="$(llmctx_routes_judge "$target")"
[[ -n "$verdict" ]] || exit 0
IFS=$'\t' read -r route_name route_path expected_dir active_name _ <<<"$verdict"

reason="This path is routed to the \"$route_name\" Claude account, but the session is on \"$active_name\".

  target             $target
  route              $route_path  ->  $route_name
  CLAUDE_CONFIG_DIR  ${CLAUDE_CONFIG_DIR:-<unset>}   (expected $expected_dir)

$(llmctx_routes_fix_text "$route_path" "$active_name" "$active_dir")"

jq -n --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
