#!/usr/bin/env bash
set -euo pipefail

# The three gates are exercised from source by their own suites, where each one
# falls back to ../lib/ for its libraries. An INSTALLED gate has no such
# fallback: it sources llmctx-<lib>.sh from beside itself and exits 0 -- allow --
# when one is missing. So a library that is renamed, or dropped from HOOK_LIBS in
# bin/build-adapters.sh, switches every gate off on every account while those
# suites stay green. This installs into a throwaway account and drives each gate
# through the command the installed settings.json registers for it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

# Installs into a throwaway $HOME and writes nothing real, so it is as exempt
# from the linked-worktree guard as tests/build-adapters-test.sh is.
export LLMCTX_ALLOW_WORKTREE_INSTALL=1

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-installed-gates.XXXXXX")"
tmp="$(cd "$tmp" && pwd)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
mkdir -p "$HOME/.claude" "$HOME/.claude-acme" "$HOME/repos/acme/app"
: >"$GIT_CONFIG_GLOBAL"
unset CLAUDE_CONFIG_DIR

fail() {
  echo "installed-gates test failed: $*" >&2
  exit 1
}

"$SRC/bin/build-adapters.sh" >/dev/null 2>&1 || fail "the adapter build failed"
settings="$HOME/.claude/settings.json"

# The irreversible gate treats $TMPDIR as scratch, and these fixtures live under
# the real one, so it is given a scratch root of its own, as in its own suite.
scratch_root="$tmp/scratch-root"
mkdir -p "$scratch_root"

decide() { # <hook basename> <payload> -> allow|ask|deny|unregistered
  local registered out
  registered="$(jq -r --arg b "/$1" \
    '[.hooks.PreToolUse[].hooks[].command | select(endswith($b))] | first // empty' "$settings")"
  if [[ -z "$registered" ]]; then
    echo unregistered
    return
  fi
  # Run it as registered: a shell command line with the payload on stdin.
  out="$(printf '%s' "$2" | TMPDIR="$scratch_root" bash -c "$registered" 2>/dev/null || true)"
  if [[ -z "${out//[[:space:]]/}" ]]; then
    echo allow
    return
  fi
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo allow
}

want() { # <expected> <hook basename> <payload> <description>
  local got
  got="$(decide "$2" "$3")"
  [[ "$got" == "$1" ]] || fail "$4: the installed $2 answered $got, expected $1"
}

repo="$tmp/repo"
git init --quiet "$repo"
git -C "$repo" symbolic-ref HEAD refs/heads/main
printf '%s\n' '{"schemaVersion":1,"profile":"client"}' >"$repo/.llmctx.json"

want deny branch-gate.sh "$(jq -nc --arg c "$repo" --arg f "$repo/README.md" \
  '{tool_name:"Edit",session_id:"t",tool_input:{file_path:$f},cwd:$c}')" \
  "an edit on a protected branch of a client repository"

# The literal is split so this file can be edited by an agent without the gate
# under test matching its own source.
PF="git"" push --force"
want ask irreversible-gate.sh "$(jq -nc --arg c "$repo" --arg cmd "$PF origin main" \
  '{tool_name:"Bash",session_id:"t",tool_input:{command:$cmd},cwd:$c}')" \
  "a force push"

# Registered after the build, so the build installed the default account only.
git config --global --add llmctx.claudeAccount "acme=$HOME/.claude-acme"
git config --global --add llmctx.accountRoute "acme=~/repos/acme"
want deny account-guard.sh "$(jq -nc --arg c "$HOME" --arg f "$HOME/repos/acme/app/x.py" \
  '{tool_name:"Edit",session_id:"t",tool_input:{file_path:$f},cwd:$c}')" \
  "an edit under a path routed to another account"

echo "installed-gates tests: passed"
