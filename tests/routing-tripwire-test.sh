#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$SRC/bin/claude-hooks/routing-tripwire.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-routing-tripwire.XXXXXX")"
tmp="$(cd "$tmp" && pwd)"
export HOME="$tmp/home"
export GIT_CONFIG_GLOBAL="$tmp/global.gitconfig"
mkdir -p "$HOME/.claude" "$HOME/.claude-acme" "$HOME/repos/acme/app" "$HOME/repos/acme/mine" "$HOME/repos/personal"
unset CLAUDE_CONFIG_DIR

fail() {
  echo "routing tripwire test failed: $*" >&2
  exit 1
}

payload() { # cwd [source]
  jq -cn --arg c "$1" --arg s "${2:-startup}" '{session_id:"test", hook_event_name:"SessionStart", source:$s, cwd:$c}'
}
run() { # cwd [CLAUDE_CONFIG_DIR] [source]
  if [[ -n "${2:-}" ]]; then
    CLAUDE_CONFIG_DIR="$2" bash "$HOOK" <<<"$(payload "$1" "${3:-startup}")"
  else
    bash "$HOOK" <<<"$(payload "$1" "${3:-startup}")"
  fi
}
# A SessionStart hook cannot block, so "fired" means it told BOTH sides: the
# agent through additionalContext, the person through systemMessage.
fired() {
  jq -e '.hookSpecificOutput.hookEventName == "SessionStart"
    and (.hookSpecificOutput.additionalContext | length > 0)
    and (.systemMessage | length > 0)' <<<"$1" >/dev/null 2>&1
}

# No routes: silent, whatever the cwd. The common case must cost nothing.
[[ -z "$(run "$HOME/repos/acme/app")" ]] || fail "fired with no routes configured"

git config --global --add llmctx.claudeAccount "acme=$HOME/.claude-acme"
git config --global --add llmctx.accountRoute "acme=~/repos/acme"

out="$(run "$HOME/repos/acme/app")"
fired "$out" || fail "a session under a routed path on the default account was not told: $out"
jq -r '.systemMessage' <<<"$out" | grep -q 'routed to the "acme" Claude account' ||
  fail "the notice did not name the expected account"
jq -r '.systemMessage' <<<"$out" | grep -q "expected $HOME/.claude-acme" ||
  fail "the notice did not name the expected config directory"
jq -r '.systemMessage' <<<"$out" | grep -q 'direnv allow' || fail "the notice did not carry the fix"
jq -r '.hookSpecificOutput.additionalContext' <<<"$out" | grep -q 'account-guard.sh refuses' ||
  fail "the agent context did not say the guard will refuse writes"
jq -r '.hookSpecificOutput.additionalContext' <<<"$out" | grep -q 'and stop' ||
  fail "the agent context did not tell the agent to stop"

# It never blocks and never fails: exit 0 whether it fires or not.
bash "$HOOK" <<<"$(payload "$HOME/repos/acme/app")" >/dev/null || fail "firing exited non-zero"

# On its own account: silent.
[[ -z "$(run "$HOME/repos/acme/app" "$HOME/.claude-acme")" ]] || fail "a session on its own account was told"
# Routes-only and symmetric: an unrouted cwd is nobody's business.
[[ -z "$(run "$HOME/repos/personal" "$HOME/.claude-acme")" ]] || fail "an unrouted cwd was judged"
[[ -z "$(run "$HOME/repos/personal")" ]] || fail "an unrouted cwd was judged on the default account"

# Every source is judged the same way: a resumed or forked session can land on
# the wrong account as easily as a new one.
for s in resume clear compact fork; do
  fired "$(run "$HOME/repos/acme/app" "" "$s")" || fail "source $s was not judged"
done

# Normalisation: symlinks, .. and ~ do not escape the route.
ln -s "$HOME/repos/acme" "$HOME/acme-link"
fired "$(run "$HOME/acme-link/app")" || fail "a symlinked cwd escaped the route"
fired "$(run "$HOME/repos/personal/../acme/app")" || fail ".. escaped the route"
# The tilde is held in a variable: shellcheck reads a quoted literal `~` as a
# failed expansion (SC2088), but this is a tilde a payload might carry.
tilde="~"
fired "$(run "$tilde/repos/acme/app")" || fail "a ~ cwd was not expanded"
# The route itself, not only a directory below it.
fired "$(run "$HOME/repos/acme")" || fail "the route directory itself was not judged"
# A trailing slash on CLAUDE_CONFIG_DIR still names the same account.
[[ -z "$(run "$HOME/repos/acme/app" "$HOME/.claude-acme//")" ]] ||
  fail "CLAUDE_CONFIG_DIR with trailing slashes was not recognised"

# Longest route wins: a nested tree can belong to the default account.
git config --global --add llmctx.accountRoute "default=~/repos/acme/mine"
[[ -z "$(run "$HOME/repos/acme/mine")" ]] || fail "nested route for the default account did not win"
fired "$(run "$HOME/repos/acme/mine" "$HOME/.claude-acme")" ||
  fail "nested default route was not enforced against the acme account"

# The sentinel suspends it for the active account only, as it does the guard.
touch "$HOME/.claude/.allow-cross-account"
[[ -z "$(run "$HOME/repos/acme/app")" ]] || fail "the sentinel did not suspend the tripwire"
rm "$HOME/.claude/.allow-cross-account"

# A route naming an unregistered account is doctor's finding, not this hook's.
git config --global --add llmctx.accountRoute "ghost=~/repos/personal"
[[ -z "$(run "$HOME/repos/personal")" ]] || fail "a route to an unregistered account was enforced"

# An unregistered CLAUDE_CONFIG_DIR cannot be judged: silent, never a wrong notice.
[[ -z "$(run "$HOME/repos/acme/app" "$tmp/elsewhere")" ]] || fail "an unregistered config dir was judged"

# A payload without a cwd, and one that is not JSON at all: silent, exit 0.
[[ -z "$(bash "$HOOK" <<<'{"session_id":"t","hook_event_name":"SessionStart","source":"startup"}')" ]] ||
  fail "a payload without cwd was judged"
out="$(
  bash "$HOOK" <<<'not json' 2>/dev/null
  echo "rc=$?"
)"
[[ "$out" == "rc=0" ]] || fail "malformed input did not fail open: $out"

# Registered under SessionStart with no matcher, so every source reaches it,
# and installed into each account beside its library.
jq -e '[.hooks.SessionStart[]? | select(has("matcher") | not) | .hooks[]?.command] | any(test("routing-tripwire\\.sh$"))' \
  "$SRC/claude/settings.json" >/dev/null || fail "claude/settings.json does not register the tripwire under SessionStart without a matcher"
LLMCTX_ALLOW_WORKTREE_INSTALL=1 "$SRC/bin/build-adapters.sh" >/dev/null 2>&1 || fail "build-adapters failed"
[[ -x "$HOME/.claude/hooks/routing-tripwire.sh" ]] || fail "the tripwire was not installed into the default account"
[[ -f "$HOME/.claude/hooks/llmctx-routes.sh" ]] || fail "the routes library was not installed beside it"
[[ -x "$HOME/.claude-acme/hooks/routing-tripwire.sh" ]] || fail "the tripwire was not installed into the acme account"
jq -e '[.hooks.SessionStart[]?.hooks[]?.command] | any(test("/hooks/routing-tripwire\\.sh$"))' \
  "$HOME/.claude/settings.json" >/dev/null || fail "the installed settings do not register the tripwire"
# The installed copy answers the same way the in-tree one does.
fired "$(CLAUDE_CONFIG_DIR="" bash "$HOME/.claude/hooks/routing-tripwire.sh" <<<"$(payload "$HOME/repos/acme/app")")" ||
  fail "the installed tripwire did not fire"

echo "routing tripwire tests: passed"
