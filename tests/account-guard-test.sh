#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$SRC/bin/claude-hooks/account-guard.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-account-guard.XXXXXX")"
tmp="$(cd "$tmp" && pwd)"
export HOME="$tmp/home"
export GIT_CONFIG_GLOBAL="$tmp/global.gitconfig"
mkdir -p "$HOME/.claude" "$HOME/.claude-acme" "$HOME/repos/acme/app" "$HOME/repos/acme/mine" "$HOME/repos/personal"
unset CLAUDE_CONFIG_DIR

fail() {
  echo "account guard test failed: $*" >&2
  exit 1
}

payload() { # tool file cwd
  jq -cn --arg t "$1" --arg f "$2" --arg c "$3" \
    '{tool_name:$t, session_id:"test", cwd:$c} + (if $f == "" then {} else {tool_input:{file_path:$f}} end)'
}
run() { # payload [CLAUDE_CONFIG_DIR]
  if [[ -n "${2:-}" ]]; then
    CLAUDE_CONFIG_DIR="$2" bash "$HOOK" <<<"$1"
  else
    bash "$HOOK" <<<"$1"
  fi
}
denied() { jq -e '.hookSpecificOutput.permissionDecision == "deny"' <<<"$1" >/dev/null 2>&1; }

# No routes: silent, whatever the path.
[[ -z "$(run "$(payload Edit "$HOME/repos/acme/app/x.py" "$HOME")")" ]] || fail "fired with no routes configured"

git config --global --add llmctx.claudeAccount "acme=$HOME/.claude-acme"
git config --global --add llmctx.accountRoute "acme=~/repos/acme"

out="$(run "$(payload Edit "$HOME/repos/acme/app/x.py" "$HOME")")"
denied "$out" || fail "edit under a routed path on the default account was not denied"
grep -q 'acme' <<<"$out" || fail "denial did not name the expected account"

[[ -z "$(run "$(payload Edit "$HOME/repos/acme/app/x.py" "$HOME")" "$HOME/.claude-acme")" ]] ||
  fail "edit under a routed path on its own account was denied"

[[ -z "$(run "$(payload Edit "$HOME/repos/personal/x.py" "$HOME")" "$HOME/.claude-acme")" ]] ||
  fail "unrouted path was judged (guard must be routes-only)"

[[ -z "$(run "$(payload Read "$HOME/repos/acme/app/x.py" "$HOME")")" ]] || fail "Read was judged"

denied "$(run "$(payload Bash "" "$HOME/repos/acme/app")")" || fail "Bash with cwd under a routed path was not denied"

# A relative file_path resolves against the payload cwd.
denied "$(run "$(payload Write "x.py" "$HOME/repos/acme/app")")" || fail "relative path under a routed cwd was not denied"

# Longest route wins: a nested tree can belong to the default account.
git config --global --add llmctx.accountRoute "default=~/repos/acme/mine"
[[ -z "$(run "$(payload Edit "$HOME/repos/acme/mine/notes.md" "$HOME")")" ]] || fail "nested route for the default account did not win"
denied "$(run "$(payload Edit "$HOME/repos/acme/mine/notes.md" "$HOME")" "$HOME/.claude-acme")" ||
  fail "nested default route was not enforced against the acme account"

# Sentinel suspends the guard for the active account only.
touch "$HOME/.claude/.allow-cross-account"
[[ -z "$(run "$(payload Edit "$HOME/repos/acme/app/x.py" "$HOME")")" ]] || fail "sentinel did not suspend the guard"
rm "$HOME/.claude/.allow-cross-account"

# A route naming an unregistered account is ignored by the hook (doctor reports it).
git config --global --add llmctx.accountRoute "ghost=~/repos/personal"
[[ -z "$(run "$(payload Edit "$HOME/repos/personal/x.py" "$HOME")")" ]] || fail "unregistered route account was enforced"

# An unregistered CLAUDE_CONFIG_DIR cannot be judged: silent, never a wrong deny.
[[ -z "$(run "$(payload Edit "$HOME/repos/acme/app/x.py" "$HOME")" "$tmp/elsewhere")" ]] || fail "unregistered config dir was judged"

echo "account guard tests: passed"
