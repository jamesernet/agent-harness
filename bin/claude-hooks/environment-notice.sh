#!/usr/bin/env bash
# SessionStart can notify the person and agent, but cannot refuse execution.
set -euo pipefail
trap 'exit 0' ERR
command -v jq >/dev/null 2>&1 || exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/llmctx-context-session.sh"
[[ -f "$LIB" ]] || LIB="$SCRIPT_DIR/../lib/context-session.sh"
# shellcheck source=../lib/context-session.sh
source "$LIB"
cwd="$(jq -er '.cwd | select(type == "string" and startswith("/"))' 2>/dev/null)" || exit 0
[[ -d "$cwd" ]] || exit 0
cwd="$(cd "$cwd" && pwd -P)"
message="$(llmctx_context_session_message "$cwd")"
[[ -n "$message" ]] || exit 0
jq -n --arg msg "$message" --arg ctx "AWS environment notice: $message Stop work in this context and explain the mismatch to the person before continuing." \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx},systemMessage:$msg}'
