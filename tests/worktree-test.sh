#!/usr/bin/env bash
set -euo pipefail

# Cover for bin/worktree.sh's layout maths.
#
# Why it exists: two regressions, both silent.
#
# 1. The parent directory was spelled "<repo>.worktrees" here while every
#    repo-local helper and the rest of the estate used "<repo>-worktrees". The
#    hyphen won, so `new` must write there while `path`/`rm` still find the dot
#    copies already on disk — otherwise the existing worktrees stop being
#    manageable by the tool that made them.
# 2. The root was resolved with `--show-toplevel`, which returns the worktree
#    you are standing in. Since the whole point is one session per worktree,
#    running the helper from inside one computed a parent nested under that
#    worktree. Observed 2026-11-10.
#
# Isolation: every repository here is created under $tmp, so the real
# repository's worktree list is never touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
WT="$SRC/bin/worktree.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-worktree-test.XXXXXX")"
# -P: git reports physical paths, so compare physical ones (/var is a symlink
# to /private/var on macOS, and a logical pwd here would never match).
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

export GIT_CONFIG_GLOBAL="$tmp/global.gitconfig"
: >"$GIT_CONFIG_GLOBAL"

fail() {
  echo "worktree test failed: $*" >&2
  exit 1
}

repo="$tmp/org/demo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" -c user.email=t@example.com -c user.name=t \
  commit -q --allow-empty -m "root"

# `new` writes to the hyphen, and flattens the slug.
(cd "$repo" && "$WT" new feature/a-slice >/dev/null)
[[ -d "$tmp/org/demo-worktrees/feature-a-slice" ]] ||
  fail "new did not create <repo>-worktrees/<slug>"
[[ ! -d "$tmp/org/demo.worktrees" ]] ||
  fail "new created the legacy dot parent"

# `path` agrees with where `new` put it.
got="$(cd "$repo" && "$WT" path feature/a-slice)"
[[ "$got" = "$tmp/org/demo-worktrees/feature-a-slice" ]] ||
  fail "path disagreed with new: $got"

# A branch with no worktree anywhere resolves to the hyphen.
got="$(cd "$repo" && "$WT" path feature/never-made)"
[[ "$got" = "$tmp/org/demo-worktrees/feature-never-made" ]] ||
  fail "path for an absent worktree was not the hyphen: $got"

# A worktree already on disk under the legacy dot parent is still found, which
# is what lets those drain instead of needing a migration.
git -C "$repo" worktree add -q -b legacy/slice \
  "$tmp/org/demo.worktrees/legacy-slice" main
got="$(cd "$repo" && "$WT" path legacy/slice)"
[[ "$got" = "$tmp/org/demo.worktrees/legacy-slice" ]] ||
  fail "path did not resolve the legacy dot layout: $got"

# Run from INSIDE a worktree: the parent must still be beside the main
# checkout, never nested under the worktree.
got="$(cd "$tmp/org/demo-worktrees/feature-a-slice" && "$WT" path feature/other)"
[[ "$got" = "$tmp/org/demo-worktrees/feature-other" ]] ||
  fail "path from inside a worktree nested the parent: $got"

# ...and from a subdirectory of a worktree, where --git-common-dir is relative.
mkdir -p "$tmp/org/demo-worktrees/feature-a-slice/nested/deeper"
got="$(cd "$tmp/org/demo-worktrees/feature-a-slice/nested/deeper" && "$WT" path feature/other)"
[[ "$got" = "$tmp/org/demo-worktrees/feature-other" ]] ||
  fail "path from a worktree subdirectory was wrong: $got"

# ...and from a subdirectory of the main checkout.
mkdir -p "$repo/sub/dir"
got="$(cd "$repo/sub/dir" && "$WT" path feature/other)"
[[ "$got" = "$tmp/org/demo-worktrees/feature-other" ]] ||
  fail "path from a main-checkout subdirectory was wrong: $got"

# `rm` removes the legacy copy, at its real location, and keeps the branch.
(cd "$repo" && "$WT" rm legacy/slice >/dev/null)
[[ ! -d "$tmp/org/demo.worktrees/legacy-slice" ]] ||
  fail "rm did not remove the legacy worktree"
git -C "$repo" show-ref --verify --quiet refs/heads/legacy/slice ||
  fail "rm deleted the branch, which it must keep"

# Outside a repository the script must fail, not invent a path. Anchoring the
# root on --git-common-dir put the substitution inside a larger string, where
# set -e cannot see it fail: `cd "/.."` succeeds, so the script printed
# "///-worktrees/<slug>" and exited 0. The zsh `wt` wrapper guards on the path
# existing, so a caller who ran this from the wrong directory got silence.
outside="$tmp/not-a-repo"
mkdir -p "$outside"
status=0
out="$(cd "$outside" && "$WT" path some/branch 2>/dev/null)" || status=$?
[[ "$status" -ne 0 ]] ||
  fail "path outside a repository exited 0 and printed: $out"
[[ -z "$out" ]] ||
  fail "path outside a repository invented a location: $out"

echo "worktree tests: passed"
