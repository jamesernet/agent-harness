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
[[ -n "$(llmctx_routes_list)" ]] || exit 0

active_dir="$(llmctx_routes_active_dir)"
[[ -e "$active_dir/.allow-cross-account" ]] && exit 0
active_name="$(llmctx_routes_active_account)"
[[ -n "$active_name" ]] || exit 0

# The payload's cwd is the only cwd a hook may trust; the process cwd is
# whatever Claude Code happened to spawn the hook in.
input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
[[ -n "$cwd" ]] || exit 0
cwd="$(llmctx_target_canonical "$(llmctx_target_expand_home "$cwd")")"
[[ "$cwd" == /* ]] || exit 0

match="$(llmctx_routes_match "$cwd")"
[[ -n "$match" ]] || exit 0
route_name="${match%%	*}"
route_path="${match#*	}"
[[ "$route_name" != "$active_name" ]] || exit 0

# A route to an account this machine has not registered is doctor's finding,
# not this hook's; a notice naming a directory that does not exist would send
# the person the wrong way.
expected_dir="$(llmctx_routes_account_dir "$route_name")"
[[ -n "$expected_dir" ]] || exit 0

message="This session started in a directory routed to the \"$route_name\" Claude account, but it is running on \"$active_name\".

  cwd                $cwd
  route              $route_path  ->  $route_name
  CLAUDE_CONFIG_DIR  ${CLAUDE_CONFIG_DIR:-<unset>}   (expected $expected_dir)

Nothing has been written yet, and account-guard.sh will refuse the first write under that route. The likely cause is a shell that never loaded direnv. From a terminal OUTSIDE this session:
  cd \"$route_path\" && direnv allow .
  # then start a new session there: claude    and confirm with /status

If a repo under that path has its own .envrc, it needs 'source_up_if_exists' as its
first line, or it shadows the parent entirely and this keeps firing.

To work here on the \"$active_name\" account deliberately, suspend the guard:
  touch \"$active_dir/.allow-cross-account\"    # then rm it when done"

agent_note="Routing tripwire: this session is on the \"$active_name\" Claude account, but its working directory is routed to \"$route_name\". Do not edit, write or run commands under $route_path on this account; account-guard.sh refuses them, and the person has been shown how to restart the session on the right account. Tell them this is why, and stop. The notice they were shown:

$message"

jq -n --arg ctx "$agent_note" --arg msg "$message" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx},systemMessage:$msg}'
