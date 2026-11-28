#!/usr/bin/env bash
set -euo pipefail

# Regression cover for the linked-worktree install guard in bin/build-adapters.sh.
#
# Why it exists: $SRC is the script's own parent, and the Claude adapter @imports
# the global files BY PATH. Installing from a linked worktree therefore rewrites
# every registered account's CLAUDE.md to import from that worktree -- a path that
# dies with the worktree, and a missing @import target is SILENT. Observed
# 2026-09-03; recovered by re-running from the primary checkout.
#
# Isolation: this clones the repository under test and adds the worktree inside
# the CLONE, so the real repository's worktree list is never touched. $HOME is a
# throwaway, so account resolution (git config --global) finds only the default.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-worktree-install-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd)"
trap 'rm -rf "$tmp"' EXIT

test_home="$tmp/home"
mkdir -p "$test_home/.claude"
export HOME="$test_home"
export GIT_CONFIG_GLOBAL="$test_home/.gitconfig"
: >"$GIT_CONFIG_GLOBAL"

fail() {
  echo "worktree-install test failed: $*" >&2
  exit 1
}

clone="$tmp/clone"
wt="$tmp/wt"

# The repository under test is BUILT FROM THE WORKING TREE, not cloned from HEAD.
# A clone carries whatever HEAD has. Copying three named inputs over one held
# only while every other input sat where HEAD had it; laying the whole working
# tree over one fixed additions and edits and still left every path the working
# tree had deleted or renamed. A commit that moves a directory the adapters read
# was then tested against a tree holding both names, where a leftover reference
# to the old one passes. Every tracked or unignored file that exists is copied
# into a new repository and committed there, so the worktree added below holds
# exactly the same tree. A nested repository is listed as a directory entry and
# skipped; a path deleted but not yet staged is listed and absent, and skipped.
# The name stays "clone" because the assertions below read naturally with it.
mkdir -p "$clone"
git -C "$clone" init --quiet
(
  cd "$SRC"
  git ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' path; do
      case "$path" in */) continue ;; esac
      if [[ -e "$path" || -L "$path" ]]; then printf '%s\0' "$path"; fi
    done |
    tar -cf - --null -T -
) | tar -xf - -C "$clone"
# -f: a tracked file that an ignore rule also matches must not drop out here.
git -C "$clone" add -A -f .
git -C "$clone" -c user.name=test -c user.email=test@example.com commit --quiet -m snapshot
git -C "$clone" worktree add --quiet --detach "$wt" HEAD

run_wt() { "$wt/bin/build-adapters.sh" "$@" >/dev/null 2>"$tmp/err"; }

# 1. A write-mode install from a linked worktree refuses, and names both paths.
if run_wt; then
  fail "installing from a linked worktree was allowed"
fi
grep -q "refusing to install adapters from a linked worktree" "$tmp/err" ||
  fail "the refusal did not say why: $(cat "$tmp/err")"
grep -qF "$wt" "$tmp/err" || fail "the refusal did not name the worktree"
grep -qF "$clone" "$tmp/err" || fail "the refusal did not name the primary checkout"

# 2. An exported GIT_DIR must not defeat it. git exports these to every hook it
#    runs, and rev-parse honours them over discovery from the cwd -- so before the
#    variables were cleared, both paths resolved to the primary and this passed.
if GIT_DIR="$clone/.git" GIT_COMMON_DIR="$clone/.git" run_wt; then
  fail "an exported GIT_DIR defeated the guard"
fi
grep -q "refusing to install adapters" "$tmp/err" ||
  fail "GIT_DIR case failed for some other reason: $(cat "$tmp/err")"

# 3. --check is exempt: it writes nothing, and the pre-commit hook calls it.
#    Its exit code is deliberately ignored -- from a throwaway $HOME it reports
#    real drift, which is not what this assertion is about. What matters is that
#    it was never REFUSED. (Guarding --check would refuse every commit made from
#    a worktree, the layout this repo's own guidance recommends.)
run_wt --check || true
if grep -q "refusing to install" "$tmp/err"; then
  fail "--check was refused from a worktree"
fi

# 4. The override is read by VALUE. `0` must not opt in.
if LLMCTX_ALLOW_WORKTREE_INSTALL=0 run_wt; then
  fail "LLMCTX_ALLOW_WORKTREE_INSTALL=0 opted IN to the install"
fi
if LLMCTX_ALLOW_WORKTREE_INSTALL=false run_wt; then
  fail "LLMCTX_ALLOW_WORKTREE_INSTALL=false opted IN to the install"
fi

# 5. An unrecognised value stops the run rather than guessing which way it meant.
if LLMCTX_ALLOW_WORKTREE_INSTALL=ture run_wt; then
  fail "a malformed override value was accepted"
fi
grep -q "must be 1/true/yes or 0/false/no" "$tmp/err" ||
  fail "a malformed override value was not explained: $(cat "$tmp/err")"

# 6. The documented override works, and warns rather than going quiet.
LLMCTX_ALLOW_WORKTREE_INSTALL=1 run_wt ||
  fail "LLMCTX_ALLOW_WORKTREE_INSTALL=1 did not allow the install: $(cat "$tmp/err")"
grep -q "installing adapters from a linked worktree" "$tmp/err" ||
  fail "the override installed silently"

# 7. The primary checkout is unaffected -- the guard must not cry wolf.
"$clone/bin/build-adapters.sh" >/dev/null 2>"$tmp/err" ||
  fail "the primary checkout was refused: $(cat "$tmp/err")"

echo "worktree-install tests passed."
