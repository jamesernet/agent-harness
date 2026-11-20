#!/usr/bin/env bash
# Portable preflight for Codex, a shell session, or any caller without hooks.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/context-session.sh
source "$SCRIPT_DIR/lib/context-session.sh"
command -v jq >/dev/null 2>&1 || {
  echo 'env session: jq is required' >&2
  exit 2
}
[[ "$#" -le 1 ]] || {
  echo 'usage: llmctx env session [directory]' >&2
  exit 2
}
root="${1:-$PWD}"
[[ -d "$root" ]] || {
  echo 'env session: no such directory' >&2
  exit 2
}
root="$(cd "$root" && pwd -P)"
message="$(llmctx_context_session_message "$root")"
if [[ -n "$message" ]]; then
  printf '%s\n' "$message"
  exit 1
fi
echo 'No AWS session finding (unbound contexts are not checked).'
