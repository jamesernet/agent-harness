#!/usr/bin/env bash
set -euo pipefail

# Claude Code SessionStart hook: the session's directory is routed to the
# account the session runs on.
#
# account-guard.sh is the gate: it refuses the first WRITE under a routed path
# from another account. By then the first model call has been made, as its own
# header says. This hook runs when the session starts, before the first prompt,
# and reads the same routes, registry and sentinel through the same library, so
# a session started on the wrong account is told so at once -- and so is the
# agent, which is the half a notice to the person alone does not cover.
#
# A SessionStart hook cannot block: Claude Code shows exit 2's stderr and the
# session proceeds. So this is a tripwire by construction. It says, it does not
# stop, and it says it to both sides in one JSON answer: additionalContext
# reaches the agent before its first prompt, systemMessage reaches the person.
# account-guard.sh still refuses the write if either ignores it.
#
# Silent in every case it cannot judge, exactly as the guard is: no routes, an
# unregistered CLAUDE_CONFIG_DIR, a route to an unregistered account, the
# sentinel, a cwd under no route, or a cwd routed to the account that is active.
# Routes-only and symmetric, so a personal directory is nobody's business.
#
# Fails OPEN on any error, matching the other hooks.
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_LIB="$SCRIPT_DIR/llmctx-target.sh"
[[ -f "$TARGET_LIB" ]] || TARGET_LIB="$SCRIPT_DIR/../lib/target.sh"
[[ -f "$TARGET_LIB" ]] || exit 0
# shellcheck source=../lib/target.sh
source "$TARGET_LIB"
ROUTES_LIB="$SCRIPT_DIR/llmctx-routes.sh"
[[ -f "$ROUTES_LIB" ]] || ROUTES_LIB="$SCRIPT_DIR/../lib/routes.sh"
[[ -f "$ROUTES_LIB" ]] || exit 0
# shellcheck source=../lib/routes.sh
source "$ROUTES_LIB"

# No routes, no work. This is the common case on a machine without clients, and
# it runs on every startup, resume, clear, compact and fork, so it must cost
# nothing.
llmctx_routes_load
[[ -n "$LLMCTX_ROUTES" ]] || exit 0

# The sentinel is judged again inside the library; it is read here first so a
# suspended tripwire never pays for jq.
[[ -e "$(llmctx_routes_active_dir)/.allow-cross-account" ]] && exit 0
# An unregistered config dir cannot be judged; said here first, the payload is
# never parsed for it.
[[ -n "$(llmctx_routes_active_account)" ]] || exit 0

# The payload's cwd is the only cwd a hook may trust; the process cwd is
# whatever Claude Code happened to spawn the hook in.
input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
[[ -n "$cwd" ]] || exit 0
cwd="$(llmctx_target_canonical "$(llmctx_target_expand_home "$cwd")")"
[[ "$cwd" == /* ]] || exit 0

# The same verdict account-guard.sh reaches at the first write, from the same
# library call, for the session cwd instead of a write target.
verdict="$(llmctx_routes_judge "$cwd")"
[[ -n "$verdict" ]] || exit 0
IFS=$'\t' read -r route_name route_path expected_dir active_name active_dir <<<"$verdict"

message="This session started in a directory routed to the \"$route_name\" Claude account, but it is running on \"$active_name\".

  cwd                $cwd
  route              $route_path  ->  $route_name
  CLAUDE_CONFIG_DIR  ${CLAUDE_CONFIG_DIR:-<unset>}   (expected $expected_dir)

account-guard.sh refuses writes under that route from this account.

$(llmctx_routes_fix_text "$route_path" "$active_name" "$active_dir")"

agent_note="Routing tripwire: this session is on the \"$active_name\" Claude account, but its working directory is routed to \"$route_name\". Do not edit, write or run commands under $route_path on this account; account-guard.sh refuses them, and the person has been shown how to restart the session on the right account. Tell them this is why, and stop. The notice they were shown:

$message"

jq -n --arg ctx "$agent_note" --arg msg "$message" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx},systemMessage:$msg}'
