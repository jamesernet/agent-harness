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

# --- --git-dir names the repository, and outranks everything -------------
#
# #103: the gate learned these spellings in #96 while this resolver still read
# only -C and cd, so from a cwd outside the target they fell back to that cwd
# and the gate never reached the branch. The answer is the directory
# CONTAINING the git dir, because `rev-parse --show-toplevel` is fatal from
# inside a `.git` and that call is the first thing branch-policy.sh makes with
# it -- the git dir itself would make it exit 0, which is the bypass.
want "--git-dir=<x>/.git resolves to <x>" \
  "$tmp/a" "git --git-dir=$tmp/a/.git commit -m x"
want "--git-dir <x>/.git, two words" \
  "$tmp/a" "git --git-dir $tmp/a/.git commit -m x"
want "--git-dir outranks -C, which only moves where it is read from" \
  "$tmp/a" "git -C $tmp/b --git-dir=$tmp/a/.git commit -m x"
want "--git-dir outranks a cd" \
  "$tmp/a" "cd $tmp/b && git --git-dir=$tmp/a/.git commit -m x"
want "--git-dir behind other global options" \
  "$tmp/a" "git -c core.pager=cat --no-pager --git-dir=$tmp/a/.git commit"
want "--git-dir behind a prefix" \
  "$tmp/a" "sudo git --git-dir=$tmp/a/.git push"
want "--git-dir with a leading path on the verb" \
  "$tmp/a" "/usr/bin/git --git-dir=$tmp/a/.git commit"
want "a tilde in the git dir is expanded" \
  "$HOME/r" "git --git-dir=~/r/.git commit"

# A git dir that is not a `.git` has no work tree containing it -- bare, or
# --separate-git-dir -- so it is returned as-is. The callers' --show-toplevel
# then fails exactly as it would have anyway.
want "a bare git dir is returned as itself" \
  "$tmp/bare.git" "git --git-dir=$tmp/bare.git push"

# --work-tree alone is NOT read: without --git-dir, git still discovers the
# repository from the cwd and only takes the files from there, so the
# repository being acted on is unchanged.
want "--work-tree alone does not set the scope" \
  "" "git --work-tree=$tmp/b commit -m x"
want "--work-tree alongside --git-dir loses to it" \
  "$tmp/a" "git --git-dir=$tmp/a/.git --work-tree=$tmp/b commit"
want "--work-tree does not override a cd either" \
  "$tmp/b" "cd $tmp/b && git --work-tree=$tmp/a commit"

# --- GIT_DIR= in front of a git verb, one tier lower --------------------
# Measured: `GIT_DIR=a git --git-dir=b rev-parse` answers for b, so the
# option wins when both are present.
want "a GIT_DIR= prefix is read" \
  "$tmp/a" "GIT_DIR=$tmp/a/.git git commit -m x"
want "the option beats the environment" \
  "$tmp/b" "GIT_DIR=$tmp/a/.git git --git-dir=$tmp/b/.git commit"
want "a GIT_DIR= prefix after a cd" \
  "$tmp/a" "cd $tmp/b && GIT_DIR=$tmp/a/.git git commit"
want "GIT_DIR= in front of something that is not git is not read" \
  "" "GIT_DIR=$tmp/a/.git make build"

# --- the verb must be git, and the option must precede the subcommand ---
# Without both, a commit message sets the scope: the message below names a
# real repository, and judging the commit there instead would be a bypass.
want "the option inside a commit message is a message" \
  "" "git commit -m \"use --git-dir=$tmp/a/.git next time\""
want "GIT_DIR= inside a commit message is a message" \
  "" "git commit -m \"GIT_DIR=$tmp/a/.git\""
want "echoing the option is echo's business" \
  "" "echo git --git-dir=$tmp/a/.git"
want "grepping for it is grep's business" \
  "" "grep -r '--git-dir=$tmp/a/.git' ."

# --- a wrapper's own argument does not hide the verb ---------------------
#
# Found by review: the prefix scan stopped at the first bare word, so
# `sudo -u root git …` and `timeout 10 git …` were never read -- a silent
# allow on a protected branch, and `timeout 10` is an ordinary shape in a
# script rather than an evasion. A flag's value is consumed only when it is
# not itself the git verb, so a valueless flag keeps git.
want "sudo with a separate flag value" \
  "$tmp/a" "sudo -u root git --git-dir=$tmp/a/.git push"
want "sudo with a valueless flag" \
  "$tmp/a" "sudo -n git --git-dir=$tmp/a/.git push"
want "timeout with a bare duration" \
  "$tmp/a" "timeout 10 git --git-dir=$tmp/a/.git commit"
want "timeout with a suffixed duration" \
  "$tmp/a" "timeout 30s git --git-dir=$tmp/a/.git commit"
want "nice with a separate flag value" \
  "$tmp/a" "nice -n 10 git --git-dir=$tmp/a/.git commit"
want "ionice with a separate flag value" \
  "$tmp/a" "ionice -c 3 git --git-dir=$tmp/a/.git commit"
want "a wrapper in front of a GIT_DIR= assignment" \
  "$tmp/a" "sudo -u root GIT_DIR=$tmp/a/.git git commit"
# ...and a wrapper does not make the NEXT bare word a verb: echo still prints.
want "a wrapper in front of echo is still echo" \
  "" "sudo echo git --git-dir=$tmp/a/.git"
want "timeout in front of echo is still echo" \
  "" "timeout 10 echo git --git-dir=$tmp/a/.git"

# --- `/.` is the same directory, and must not read as the git dir --------
#
# Also found by review: `/r/.git/./` answered `/r/.git/.` -- the git dir
# itself, where --show-toplevel is fatal -- which is exactly the bypass the
# containing-directory rule exists to avoid.
want "a trailing /./ on the git dir" \
  "$tmp/a" "git --git-dir=$tmp/a/.git/./ commit"
want "a trailing /. on the git dir" \
  "$tmp/a" "git --git-dir=$tmp/a/.git/. commit"
want "a trailing slash on the git dir" \
  "$tmp/a" "git --git-dir=$tmp/a/.git/ commit"

# A quoted path containing whitespace stays "cannot tell": it truncates to a
# non-directory and every caller's own existence test rejects it. Capturing it
# needs a tokenizer, and a guard that half-parses shell is wrong both ways.
got="$(llmctx_target_from_command "git --git-dir=\"$tmp/a dir/.git\" commit")"
[[ "$got" != "$tmp/a dir" ]] ||
  fail "a quoted path with a space was captured whole, which this does not claim to do"

echo "target lib tests: passed"
