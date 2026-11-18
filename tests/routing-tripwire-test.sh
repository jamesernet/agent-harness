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
# Both hooks read the sentinel before they parse a payload, so the library's own
# sentinel case is reached by no hook; it is part of judge's contract, so it is
# pinned here directly, for the caller that does not pre-check.
judge() { (
  # shellcheck source=../bin/lib/routes.sh
  source "$SRC/bin/lib/routes.sh"
  llmctx_routes_judge "$1"
); }
[[ -z "$(judge "$HOME/repos/acme/app")" ]] || fail "the library judged a path under the sentinel"
rm "$HOME/.claude/.allow-cross-account"
# The route path comes back canonical, which on macOS is /private/var for a
# mktemp home; the path handed in is the uncanonical spelling on purpose, since
# that is the mistake a caller would make.
[[ "$(judge "$HOME/repos/acme/app")" == "acme	$(cd "$HOME/repos/acme" && pwd -P)	$HOME/.claude-acme	default	"* ]] ||
  fail "the library's verdict is not route, route path, expected dir, active name: $(judge "$HOME/repos/acme/app")"

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

# --- doctor: a repository .envrc under a routed tree must source its parent ---
# direnv loads only the nearest .envrc, so a repository file that does not
# begin with source_up_if_exists shadows the directory-level one carrying
# CLAUDE_CONFIG_DIR, silently, and the routing does not apply there. The two
# hooks above then catch it at run time; doctor names the file before that.
git config --global --unset-all llmctx.accountRoute
git config --global --add llmctx.accountRoute "acme=~/repos/acme"
envrc_check() { # -> the envrc-source-up check as compact JSON
  HOME="$HOME" "$SRC/bin/doctor.sh" --json >"$tmp/doctor.json" 2>/dev/null || true
  jq -c '[.checks[] | select(.id == "envrc-source-up")][0]' "$tmp/doctor.json"
}
# The routed directory's own .envrc is the parent and is never judged.
printf 'export CLAUDE_CONFIG_DIR="$HOME/.claude-acme"\n' >"$HOME/repos/acme/.envrc"
r="$(envrc_check)"
[[ "$(jq -r .status <<<"$r")" == PASS && "$(jq -r .detail <<<"$r")" == *"no repository .envrc"* ]] ||
  fail "a routed tree with only the parent .envrc was not a pass: $r"
# Comments and blank lines before the directive are fine, and so is plain source_up.
printf '# repo\n\n  source_up_if_exists\nexport FOO=1\n' >"$HOME/repos/acme/app/.envrc"
mkdir -p "$HOME/repos/acme/app-worktrees/slug"
printf 'source_up\n' >"$HOME/repos/acme/app-worktrees/slug/.envrc"
r="$(envrc_check)"
[[ "$(jq -r .status <<<"$r")" == PASS && "$(jq -r .detail <<<"$r")" == "2 repository .envrc"* ]] ||
  fail "two sourcing .envrc files were not counted as a pass: $r"
# Presence, not position: the direnv stdlib pattern puts strict_env first, and
# a file like that does load its parent. A commented-out directive does not.
printf 'strict_env\ndotenv_if_exists\nsource_up_if_exists\n' >"$HOME/repos/acme/app/.envrc"
r="$(envrc_check)"
[[ "$(jq -r .status <<<"$r")" == PASS ]] || fail "strict_env before the directive was reported as shadowing: $r"
# direnv's other way to load a parent, and a directive behind a guard or
# followed by a semicolon, all load it; a check that fails them gets ignored.
for loads in 'source_env_if_exists ../.envrc' 'source_env ../../.envrc' '[ -f ../.envrc ] && source_up_if_exists' 'source_up_if_exists;'; do
  printf '%s\nexport FOO=1\n' "$loads" >"$HOME/repos/acme/app/.envrc"
  r="$(envrc_check)"
  [[ "$(jq -r .status <<<"$r")" == PASS ]] || fail "'$loads' was reported as shadowing: $r"
done
# source_env with a LOCAL argument loads no parent: the common `.envrc.local`
# idiom is the shadowing file itself, and the first broadening of this check
# let it through. Named, every time.
for shadows in 'source_env_if_exists .envrc.local' 'source_env ./local.env' 'dotenv' 'my_source_up_if_exists'; do
  printf '%s\nexport FOO=1\n' "$shadows" >"$HOME/repos/acme/app/.envrc"
  r="$(envrc_check)"
  [[ "$(jq -r .status <<<"$r")" == FAIL && "$(jq -r .detail <<<"$r")" == *"repos/acme/app/.envrc"* ]] ||
    fail "'$shadows' loads no parent and was not named: $r"
done
# One that exports without sourcing up, one with the directive only in a
# comment, and an empty one, all shadow. Files under .git and node_modules are
# not repositories and are not walked, at depth one under the route as well as
# below a repository: -mindepth would have suppressed the prune at depth one.
printf 'export FOO=1\n' >"$HOME/repos/acme/mine/.envrc"
printf '# source_up_if_exists\nexport FOO=1\n' >"$HOME/repos/acme/app/.envrc"
: >"$HOME/repos/acme/app-worktrees/slug/.envrc"
mkdir -p "$HOME/repos/acme/node_modules/pkg" "$HOME/repos/acme/.git" "$HOME/repos/acme/mine/node_modules" "$HOME/repos/acme/mine/.git"
printf 'export X=1\n' >"$HOME/repos/acme/node_modules/pkg/.envrc"
printf 'export X=1\n' >"$HOME/repos/acme/.git/.envrc"
printf 'export X=1\n' >"$HOME/repos/acme/mine/node_modules/.envrc"
printf 'export X=1\n' >"$HOME/repos/acme/mine/.git/.envrc"
r="$(envrc_check)"
[[ "$(jq -r .status <<<"$r")" == FAIL ]] || fail "shadowing .envrc files were not reported: $r"
detail="$(jq -r .detail <<<"$r")"
[[ "$detail" == *"repos/acme/mine/.envrc"* ]] || fail "the exporting .envrc was not named: $r"
[[ "$detail" == *"app-worktrees/slug/.envrc"* ]] || fail "the empty .envrc was not named: $r"
[[ "$detail" == *"repos/acme/app/.envrc"* ]] || fail "a commented-out directive was taken as sourcing: $r"
[[ "$detail" != *"repos/acme/.envrc"* ]] || fail "the parent .envrc was judged: $r"
[[ "$detail" != *node_modules* && "$detail" != *"/.git/"* ]] || fail "pruned directories were walked: $r"
[[ "$(jq -r .remediation <<<"$r")" == *source_up_if_exists* ]] || fail "the fix did not name the directive: $r"
# A route to an unregistered account fails the routes check; it does not make
# this one vanish, and the files under the valid route are still named.
git config --global --add llmctx.accountRoute "ghost=~/repos/personal"
r="$(envrc_check)"
[[ "$(jq -r .status <<<"$r")" == FAIL && "$(jq -r .detail <<<"$r")" == *"repos/acme/mine/.envrc"* ]] ||
  fail "a bad route hid the envrc check: $r"
git config --global --unset llmctx.accountRoute "ghost=~/repos/personal"
# Fixed, it clears.
printf 'source_up_if_exists\nexport FOO=1\n' >"$HOME/repos/acme/mine/.envrc"
printf 'source_up_if_exists\n' >"$HOME/repos/acme/app-worktrees/slug/.envrc"
printf 'source_up_if_exists\n' >"$HOME/repos/acme/app/.envrc"
r="$(envrc_check)"
[[ "$(jq -r .status <<<"$r")" == PASS ]] || fail "fixing the files did not clear the check: $r"
# A route whose directory does not exist is skipped here; the routes check owns it.
git config --global --add llmctx.accountRoute "acme=~/repos/nowhere"
r="$(envrc_check)"
[[ "$(jq -r .status <<<"$r")" == PASS ]] || fail "a route to a missing directory broke the check: $r"

echo "routing tripwire tests: passed"
