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
jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$out" | grep -q 'routed to the "acme" Claude account' ||
  fail "denial did not name the expected account"

[[ -z "$(run "$(payload Edit "$HOME/repos/acme/app/x.py" "$HOME")" "$HOME/.claude-acme")" ]] ||
  fail "edit under a routed path on its own account was denied"

[[ -z "$(run "$(payload Edit "$HOME/repos/personal/x.py" "$HOME")" "$HOME/.claude-acme")" ]] ||
  fail "unrouted path was judged (guard must be routes-only)"

[[ -z "$(run "$(payload Read "$HOME/repos/acme/app/x.py" "$HOME")")" ]] || fail "Read was judged"

denied "$(run "$(payload Bash "" "$HOME/repos/acme/app")")" || fail "Bash with cwd under a routed path was not denied"

# A relative file_path resolves against the payload cwd.
denied "$(run "$(payload Write "x.py" "$HOME/repos/acme/app")")" || fail "relative path under a routed cwd was not denied"

# Bash is judged by the directory the command names, not the session cwd.
bash_payload() { jq -cn --arg c "$1" --arg d "$2" '{tool_name:"Bash", session_id:"test", cwd:$d, tool_input:{command:$c}}'; }
denied "$(run "$(bash_payload "cd $HOME/repos/acme/app && echo hi > y.py" "$HOME/repos/personal")")" ||
  fail "cd into a routed tree from a personal cwd was not denied"
denied "$(run "$(bash_payload "git -C $HOME/repos/acme/app commit -am x" "$HOME/repos/personal")")" ||
  fail "git -C into a routed tree was not denied"
denied "$(run "$(bash_payload "W=$HOME/repos/acme/app; cd \"\$W\" && make" "$HOME/repos/personal")")" ||
  fail "cd through a variable assigned in the same command was not followed"
[[ -z "$(run "$(bash_payload "cd $HOME/repos/personal && ls" "$HOME/repos/acme/app")")" ]] ||
  fail "cd out of a routed tree was still denied"
# The remediation the denial prints must itself be allowed.
[[ -z "$(run "$(bash_payload "touch $HOME/.claude/.allow-cross-account" "$HOME/repos/acme/app")")" ]] ||
  fail "touching the sentinel from inside the routed tree was denied"
[[ -z "$(run "$(payload Write "$HOME/.claude/.allow-cross-account" "$HOME/repos/acme/app")")" ]] ||
  fail "writing the sentinel with the Write tool was denied"

# Normalisation: .. and symlinks do not escape the route.
denied "$(run "$(payload Edit "$HOME/repos/personal/../acme/app/x.py" "$HOME")")" || fail ".. bypassed the route"
denied "$(run "$(payload Edit "../acme/app/x.py" "$HOME/repos/personal")")" || fail "relative .. bypassed the route"
ln -s "$HOME/repos/acme" "$HOME/acme-link"
denied "$(run "$(payload Edit "$HOME/acme-link/app/x.py" "$HOME")")" || fail "symlink bypassed the route"
denied "$(run "$(payload Edit "$HOME/repos/acme/app/new-dir/new-file.py" "$HOME")")" || fail "a path whose parent does not exist yet escaped the route"
# A route set through a symlink, a double slash, or a trailing slash still matches.
git config --global --unset-all llmctx.accountRoute
git config --global --add llmctx.accountRoute "acme=~/acme-link/"
denied "$(run "$(payload Edit "$HOME/repos/acme/app/x.py" "$HOME")")" || fail "route via symlink did not match the real path"
[[ -z "$(run "$(payload Edit "$HOME/repos/acme/app/x.py" "$HOME")" "$HOME/.claude-acme//")" ]] ||
  fail "CLAUDE_CONFIG_DIR with a double trailing slash was not recognised"
git config --global --unset-all llmctx.accountRoute
git config --global --add llmctx.accountRoute "acme=~/repos/acme"

# A relative route never matches; doctor is what reports it (below).
git config --global --add llmctx.accountRoute "acme=repos/acme"
[[ -z "$(run "$(payload Edit "$HOME/repos/acme/app/x.py" "$HOME/repos")" "$HOME/.claude-acme")" ]] || fail "relative route matched"
git config --global --unset llmctx.accountRoute "acme=repos/acme"

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

# Doctor: a default= route is valid under --account <other>, and a relative
# route is reported rather than silently never matching.
git config --global --unset-all llmctx.accountRoute
git config --global --add llmctx.accountRoute "acme=~/repos/acme"
git config --global --add llmctx.accountRoute "default=~/repos/acme/mine"
HOME="$HOME" "$SRC/bin/doctor.sh" --json --account acme >"$tmp/doctor.json" 2>/dev/null || true
jq -e '.checks[] | select(.id == "account-routes") | .status == "PASS"' "$tmp/doctor.json" >/dev/null ||
  fail "doctor --account failed a valid default route"
git config --global --add llmctx.accountRoute "acme=repos/relative"
HOME="$HOME" "$SRC/bin/doctor.sh" --json >"$tmp/doctor.json" 2>/dev/null || true
jq -e '.checks[] | select(.id == "account-routes") | .status == "FAIL" and (.detail | contains("not absolute"))' "$tmp/doctor.json" >/dev/null ||
  fail "doctor did not report a relative route"

echo "account guard tests: passed"
