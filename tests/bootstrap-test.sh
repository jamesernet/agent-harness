#!/usr/bin/env bash
set -euo pipefail

# bin/bootstrap.sh against a copy of this repository, for the one path that
# destroyed data while printing success: install-git-hooks.sh preserves a
# foreign pre-commit as pre-commit.local, and bootstrap then copied its own
# local-checks hook over the same path, unconditionally (#57). Both steps
# printed reassuring output.
#
# Built on the doctor test's copy idiom: tar without .git, then git init, so
# the real repository's hooks are never touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-bootstrap-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd)"
trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_GLOBAL="$tmp/global.gitconfig"
: >"$GIT_CONFIG_GLOBAL"

fail() {
  echo "bootstrap test failed: $*" >&2
  exit 1
}

fresh_copy() { # fresh_copy <name> -> path
  local copy="$tmp/$1"
  mkdir -p "$copy"
  tar -C "$SRC" --exclude=.git -cf - . | tar -C "$copy" -xf -
  git -C "$copy" init -q
  printf '%s' "$copy"
}

# 1. A clean checkout: bootstrap installs this repository's local checks.
copy="$(fresh_copy clean)"
home="$tmp/home-clean"
mkdir -p "$home"
HOME="$home" "$copy/bin/bootstrap.sh" >"$tmp/clean.out" 2>&1 ||
  fail "bootstrap exited non-zero on a clean copy: $(tail -5 "$tmp/clean.out")"
hooks_dir="$copy/.git/hooks"
cmp -s "$SRC/bin/git-hooks/pre-commit-local.agent-harness" "$hooks_dir/pre-commit.local" ||
  fail "pre-commit.local is not this repository's local-checks hook after a clean bootstrap"
grep -q 'installed pre-commit.local' "$tmp/clean.out" || fail "clean bootstrap did not report the local hook"

# 2. Run again: our own hook is refreshed, not refused — an upgrade must not
#    read a previous version of this same file as foreign.
HOME="$home" "$copy/bin/bootstrap.sh" >"$tmp/again.out" 2>&1 ||
  fail "a second bootstrap exited non-zero: $(tail -5 "$tmp/again.out")"
grep -q 'installed pre-commit.local' "$tmp/again.out" || fail "a second bootstrap did not refresh the local hook"

# 3. A checkout that already has a FOREIGN pre-commit. The installer preserves
#    it as pre-commit.local; bootstrap must then leave it there, say so, and
#    exit non-zero — not print "preserved:" and overwrite it.
copy="$(fresh_copy foreign)"
home="$tmp/home-foreign"
mkdir -p "$home" "$copy/.git/hooks"
printf '%s\n' '#!/bin/sh' '# husky' 'echo foreign hook ran' >"$copy/.git/hooks/pre-commit"
chmod +x "$copy/.git/hooks/pre-commit"
status=0
HOME="$home" "$copy/bin/bootstrap.sh" >"$tmp/foreign.out" 2>&1 || status=$?
grep -q '^preserved: existing pre-commit' "$tmp/foreign.out" ||
  fail "test setup: the installer did not preserve the foreign hook: $(head -5 "$tmp/foreign.out")"
grep -q 'echo foreign hook ran' "$copy/.git/hooks/pre-commit.local" ||
  fail "the preserved foreign hook was overwritten: $(head -3 "$copy/.git/hooks/pre-commit.local")"
[[ "$status" -ne 0 ]] || fail "bootstrap exited 0 after refusing to install the local hook"
grep -q 'NOT overwriting' "$tmp/foreign.out" || fail "bootstrap did not say it left the foreign hook alone"
grep -q 'was NOT installed' "$tmp/foreign.out" || fail "the summary did not name what did not happen"
# The rest of bootstrap still ran: the branch backstop is in place and chains
# to the preserved hook, so the foreign checks keep running.
grep -q 'llmctx-hook' "$copy/.git/hooks/pre-commit" || fail "the branch backstop was not installed alongside the refusal"
[[ -d "$home/.claude/skills" ]] || fail "skills were not installed after the refusal"

echo "bootstrap tests: passed"
