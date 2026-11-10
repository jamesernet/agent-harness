#!/usr/bin/env bash
set -euo pipefail

# bin/lib/target.sh — the shared "which directory does this command act on"
# resolver, extracted from branch-policy.sh and account-guard.sh.
#
# Every case below was behaviour one of those two hooks already had. The suite
# exists so the two can never diverge again without a test saying so.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../bin/lib/target.sh
source "$SRC/bin/lib/target.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-target-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/a" "$tmp/b"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# want <description> <expected> <command>
want() {
  local desc="$1" expected="$2" cmd="$3" got
  got="$(llmctx_target_from_command "$cmd")"
  [[ "$got" == "$expected" ]] ||
    fail "$desc: expected '$expected', got '$got'"
}

# --- `git -C` states its own target, and outranks a cd -------------------
want "git -C names its target" \
  "$tmp/a" "git -C $tmp/a commit -m x"
want "git -C outranks a preceding cd" \
  "$tmp/a" "cd $tmp/b && git -C $tmp/a commit -m x"

# --- a statement-initial cd ---------------------------------------------
want "bare cd before &&" \
  "$tmp/a" "cd $tmp/a && git commit -m x"
want "cd on its own line in a multi-line script" \
  "$tmp/a" "$(printf 'cd %s\ngit commit -m x\n' "$tmp/a")"
want "quoted cd target" \
  "$tmp/a" "cd \"$tmp/a\" && git commit -m x"

# The measured regression that produced last-wins. A cd behind a prefix is
# real, and the LAST cd is the one the shell honours.
want "cd behind a prefix is still honoured" \
  "$tmp/a" "lsof -t . | xargs kill; cd $tmp/a && git commit -m x"
want "last cd wins, which is what the shell does" \
  "$tmp/b" "cd $tmp/a && cd $tmp/b && git commit -m x"

# --- command substitutions are stripped first ---------------------------
# A cd inside $( ) runs in a subshell whose directory never reaches the outer
# command, so it must not be honoured.
want "cd inside a command substitution is ignored" \
  "" "git commit -m \"\$(cd $tmp/a && pwd)\""
want "cd inside backticks is ignored" \
  "" "git commit -m \"\`cd $tmp/a && pwd\`\""

# --- a variable assigned in the same command ----------------------------
want "VAR assigned on a previous line" \
  "$tmp/a" "$(printf 'W=%s\ncd "$W"\ngit commit -m x\n' "$tmp/a")"
want "VAR assigned on the same line with a semicolon" \
  "$tmp/a" "W=$tmp/a; cd \"\$W\" && git commit -m x"
want "braced \${VAR}" \
  "$tmp/a" "W=$tmp/a; cd \"\${W}\" && git commit -m x"
want "an assignment mid-statement is not read as one" \
  "" "git commit --flag=$tmp/a; cd \"\$W\""

# --- tilde --------------------------------------------------------------
want "leading ~/ is expanded" \
  "$HOME/sub" 'cd ~/sub && git commit -m x'
want "bare ~ is expanded" \
  "$HOME" 'cd ~ && git commit -m x'
want "~ inside an assigned value is expanded" \
  "$HOME/sub" 'W=~/sub; cd "$W" && git commit -m x'

# --- cannot tell --------------------------------------------------------
want "no cd and no -C yields nothing" \
  "" "git commit -m x"
want "empty command yields nothing" \
  "" ""

# THE ONE DIVERGENCE, decided. An unresolvable variable means "cannot tell",
# so the caller falls back to the cwd it was given rather than matching a
# route on the strength of a path nobody wrote. branch-policy.sh's effective
# behaviour is unchanged (its -d test already rejected the literal);
# account-guard.sh becomes strictly more careful.
want "an unresolvable \$VAR yields nothing rather than the literal" \
  "" 'cd "$NOT_ASSIGNED_HERE" && git commit -m x'

# --- a relative path is returned as written -----------------------------
# The caller resolves it against the payload cwd, which is the only cwd either
# hook may trust.
want "a relative cd is returned unresolved" \
  "sub/dir" "cd sub/dir && git commit -m x"

# --- a path that does not exist is still returned -----------------------
# Existence is the caller's policy, not this library's.
want "a non-existent absolute path is returned" \
  "$tmp/nope" "cd $tmp/nope && git commit -m x"

echo "target lib tests: passed"
