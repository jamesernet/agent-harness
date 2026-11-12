#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-git-hook-test.XXXXXX")"
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" symbolic-ref HEAD refs/heads/main
export GIT_CONFIG_GLOBAL="$tmp/global.gitconfig"

fail() {
  echo "git hook test failed: $*" >&2
  exit 1
}

"$SRC/bin/install-git-hooks.sh" "$repo" >/dev/null
hooks_dir="$(git -C "$repo" rev-parse --git-path hooks)"
case "$hooks_dir" in /*) ;; *) hooks_dir="$repo/$hooks_dir" ;; esac
hook="$hooks_dir/pre-commit"
policy_lib="$hooks_dir/llmctx-policy.sh"
[[ -x "$hook" ]] || fail "pre-commit hook was not installed"
cmp "$SRC/bin/lib/policy.sh" "$policy_lib" >/dev/null || fail "policy library was not installed"

# A second run over a current install says so and writes nothing; a hook or a
# policy library that has fallen behind is named as refreshed. The no-argument
# run is the estate's refresh, and `refreshed:` is the guard that had silently
# stopped matching the policy it enforces (#85).
out="$("$SRC/bin/install-git-hooks.sh" "$repo")"
grep -q "^current: $repo\$" <<<"$out" || fail "a second run did not report the repo current: $out"
grep -q '^git hooks: 1 current, 0 refreshed, 0 installed, 0 skipped$' <<<"$out" || fail "no summary line: $out"
printf '%s\n' '# older' >>"$policy_lib"
out="$("$SRC/bin/install-git-hooks.sh" "$repo")"
grep -q "^refreshed: $repo (policy library)\$" <<<"$out" || fail "a stale policy library was not reported refreshed: $out"
cmp "$SRC/bin/lib/policy.sh" "$policy_lib" >/dev/null || fail "a stale policy library was not refreshed"
printf '%s\n' '# older' >>"$hook"
printf '%s\n' '# older' >>"$policy_lib"
out="$("$SRC/bin/install-git-hooks.sh" "$repo")"
grep -q "^refreshed: $repo (hook, policy library)\$" <<<"$out" || fail "a stale hook and library were not both named: $out"
cmp "$SRC/bin/git-hooks/pre-commit" "$hook" >/dev/null || fail "a stale hook was not refreshed"

printf '%s\n' '{"schemaVersion":1,"profile":"client"}' >"$repo/.llmctx.json"
if (cd "$repo" && "$hook" >/dev/null 2>&1); then
  fail "client policy did not block main"
fi

git -C "$repo" config --local llmctx.branchPolicy off
(cd "$repo" && "$hook" >/dev/null 2>&1) || fail "local off override did not allow"
git -C "$repo" config --local --unset llmctx.branchPolicy

printf '%s\n' '{"schemaVersion":99,"profile":"client"}' >"$repo/.llmctx.json"
(cd "$repo" && "$hook" >/dev/null 2>&1) || fail "invalid policy did not fail open"

printf '%s\n' '{"schemaVersion":1,"profile":"client"}' >"$repo/.llmctx.json"
git -C "$repo" symbolic-ref HEAD refs/heads/feature/test
(cd "$repo" && "$hook" >/dev/null 2>&1) || fail "feature branch was blocked"

# The llmctx.repo registry. HOME is redirected so the built-in repo paths
# resolve inside the sandbox and this test can never install into a real repo.
reg_home="$tmp/reghome"
mkdir -p "$reg_home"

mkreg_repo() {
  local path="$1"
  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" symbolic-ref HEAD refs/heads/main
}

mkreg_repo "$reg_home/registered"
mkreg_repo "$reg_home/tilde-registered"

git config --global --add llmctx.repo "$reg_home/registered"
# shellcheck disable=SC2088  # a literal tilde is what gets stored and expanded
git config --global --add llmctx.repo '~/tilde-registered'
git config --global --add llmctx.repo "$reg_home/registered"

out="$(HOME="$reg_home" "$SRC/bin/install-git-hooks.sh")"

[[ -x "$reg_home/registered/.git/hooks/pre-commit" ]] ||
  fail "registered repo did not get the hook"
[[ -x "$reg_home/tilde-registered/.git/hooks/pre-commit" ]] ||
  fail "a ~-prefixed registration was not expanded"

# A `~user` registration is a path a shell would have expanded; this tool
# does not, and it used to say `skip: ~other/path (not a git repo)` -- which
# may be a perfectly good repository, and names the wrong cause (#92). It is
# refused by name, counted as skipped, and the good entries beside it still
# install.
# shellcheck disable=SC2088  # a literal tilde is what gets stored
git config --global --add llmctx.repo '~someone-else/project'
out_tilde="$(HOME="$reg_home" "$SRC/bin/install-git-hooks.sh" 2>&1)"
printf '%s\n' "$out_tilde" | grep -q 'skip: ~someone-else/project (unexpanded tilde' ||
  fail "a ~user registration did not name the tilde: $(printf '%s\n' "$out_tilde" | grep -i 'someone-else' || echo '(no line)')"
printf '%s\n' "$out_tilde" | grep -q 'someone-else/project (not a git repo)' &&
  fail "a ~user registration still blamed the repository"
[[ -x "$reg_home/registered/.git/hooks/pre-commit" ]] ||
  fail "a ~user registration stopped the good entries beside it installing"
git config --global --unset llmctx.repo '~someone-else/project'

installed_twice="$(printf '%s\n' "$out" | grep -c "installed pre-commit -> $reg_home/registered$" || true)"
[[ "$installed_twice" -eq 1 ]] ||
  fail "a repo registered twice was installed $installed_twice times, expected 1"

# Additive, not a replacement: the built-ins are still attempted. Inside the
# sandbox they do not exist, so each one reports as skipped rather than silently
# dropping out of the list.
printf '%s\n' "$out" | grep -q "skip: $reg_home/repos/github.com/jamesernet/agent-harness" ||
  fail "the built-in repos were replaced by the registry instead of extended"

# An explicit argument list is neither the built-ins nor the registry.
mkreg_repo "$reg_home/explicit"
out="$(HOME="$reg_home" "$SRC/bin/install-git-hooks.sh" "$reg_home/explicit")"
printf '%s\n' "$out" | grep -q "$reg_home/registered" &&
  fail "an explicit repo list did not override the registry"

# --- the scaffold's placeholder asks to be replaced ---------------------------
#
# project-scaffold writes a pre-commit whose body is `exec pre-commit.local`,
# marked scaffold-hook-shim, so the repo's committed guard runs before this
# installer arrives. It read as foreign; pre-commit.local existed; the install
# took the hard skip and the repository got no policy resolution (#59).
shim_repo="$tmp/shim"
mkdir -p "$shim_repo"
git -C "$shim_repo" init -q
shim_hooks="$(git -C "$shim_repo" rev-parse --git-path hooks)"
case "$shim_hooks" in /*) ;; *) shim_hooks="$shim_repo/$shim_hooks" ;; esac
mkdir -p "$shim_hooks"
printf '%s\n' '#!/bin/sh' '# scaffold-hook-shim — placeholder, NOT the real guard.' \
  'exec "$(dirname "$0")/pre-commit.local" "$@"' >"$shim_hooks/pre-commit"
printf '%s\n' '#!/bin/sh' 'echo committed guard ran' >"$shim_hooks/pre-commit.local"
chmod +x "$shim_hooks/pre-commit" "$shim_hooks/pre-commit.local"
out="$("$SRC/bin/install-git-hooks.sh" "$shim_repo" 2>&1)"
[[ "$out" != *"skip:"* ]] || fail "the scaffold shim was treated as a foreign hook: $out"
grep -q 'llmctx-hook' "$shim_hooks/pre-commit" || fail "the scaffold shim was not replaced by the backstop"
grep -q 'committed guard ran' "$shim_hooks/pre-commit.local" ||
  fail "replacing the shim disturbed the repository's own pre-commit.local"
# A genuinely foreign hook beside a pre-commit.local is still the hard skip.
foreign_repo="$tmp/foreign"
mkdir -p "$foreign_repo"
git -C "$foreign_repo" init -q
foreign_hooks="$(git -C "$foreign_repo" rev-parse --git-path hooks)"
case "$foreign_hooks" in /*) ;; *) foreign_hooks="$foreign_repo/$foreign_hooks" ;; esac
mkdir -p "$foreign_hooks"
printf '%s\n' '#!/bin/sh' '# husky' 'echo husky' >"$foreign_hooks/pre-commit"
printf '%s\n' '#!/bin/sh' 'echo local' >"$foreign_hooks/pre-commit.local"
out="$("$SRC/bin/install-git-hooks.sh" "$foreign_repo" 2>&1)"
[[ "$out" == *"skip:"*"resolve manually"* ]] || fail "a foreign hook beside pre-commit.local was not skipped: $out"
grep -q husky "$foreign_hooks/pre-commit" || fail "a foreign hook was overwritten"

echo "git hook tests: passed"
