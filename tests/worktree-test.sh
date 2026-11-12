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
# 3. The fix for (2) anchored on --git-common-dir, which in a SUBMODULE checkout
#    is <outer>/.git/modules/<sub>, so the parent landed INSIDE the
#    superproject's .git. The root is now asserted from --show-toplevel unless
#    the checkout is a linked worktree, and a linked worktree whose shared git
#    dir is not a ".git" beside a checkout is refused. Observed 2026-11-11.
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

# A bare repository has no checkout for a worktree to sit beside, and must be
# refused rather than answered. --git-common-dir returns "." there, so anchoring
# on it alone put the parent one level ABOVE the bare repo and exited 0 — the
# same invented-path failure as the out-of-repo case, reached through a repo that
# does exist.
bare="$tmp/bare.git"
git init -q --bare "$bare"
status=0
out="$(cd "$bare" && "$WT" path some/branch 2>/dev/null)" || status=$?
[[ "$status" -ne 0 ]] ||
  fail "path in a bare repository exited 0 and printed: $out"
[[ -z "$out" ]] ||
  fail "path in a bare repository invented a location: $out"

# A submodule's own checkout IS a main checkout, so its worktrees land beside
# it (<outer>/sub-worktrees), exactly as main behaved -- never under the
# superproject's .git, which is where anchoring on --git-common-dir
# (<outer>/.git/modules/sub, parent <outer>/.git/modules) put them.
# protocol.file.allow: git >= 2.38.1 refuses file:// submodules by default.
sub_origin="$tmp/sub-origin"
git init -q -b main "$sub_origin"
git -C "$sub_origin" -c user.email=t@example.com -c user.name=t \
  commit -q --allow-empty -m "sub root"
outer="$tmp/org/outer"
mkdir -p "$outer"
git -C "$outer" init -q -b main
git -C "$outer" -c user.email=t@example.com -c user.name=t \
  commit -q --allow-empty -m "outer root"
git -C "$outer" -c protocol.file.allow=always submodule add -q "$sub_origin" sub
git -C "$outer" -c user.email=t@example.com -c user.name=t \
  commit -q -m "add sub"
got="$(cd "$outer/sub" && "$WT" path feature/x)"
[[ "$got" = "$tmp/org/outer/sub-worktrees/feature-x" ]] ||
  fail "path from a submodule checkout was not beside the submodule: $got"
mkdir -p "$outer/sub/deep/er"
got="$(cd "$outer/sub/deep/er" && "$WT" path feature/x)"
[[ "$got" = "$tmp/org/outer/sub-worktrees/feature-x" ]] ||
  fail "path from a submodule subdirectory was wrong: $got"
(cd "$outer/sub" && "$WT" new feature/x >/dev/null)
[[ -d "$tmp/org/outer/sub-worktrees/feature-x" ]] ||
  fail "new from a submodule did not create <outer>/sub-worktrees/<slug>"
[[ ! -e "$outer/.git/modules-worktrees" ]] ||
  fail "new from a submodule wrote inside the superproject's .git"

# A linked worktree OF a submodule has a shared git dir that is not a ".git"
# beside any checkout, so there is nowhere honest to lay out worktrees. It
# must refuse by name rather than answer -- this is the only input that
# reaches the refusal, so it is what keeps that branch from being dead code.
git -C "$outer/sub" worktree add -q -b sub/linked "$tmp/sub-linked" main
status=0
out="$(cd "$tmp/sub-linked" && "$WT" path some/branch 2>"$tmp/sub-linked.err")" || status=$?
[[ "$status" -ne 0 ]] ||
  fail "path from a linked worktree of a submodule exited 0 and printed: $out"
[[ -z "$out" ]] ||
  fail "path from a linked worktree of a submodule invented a location: $out"
grep -q submodule "$tmp/sub-linked.err" ||
  fail "the refusal did not say why: $(cat "$tmp/sub-linked.err")"

# Entered through a symlink, the answer is still the physical path, because
# that is the spelling git records and `git worktree remove` matches against.
ln -s "$repo" "$tmp/via-link"
got="$(cd "$tmp/via-link" && "$WT" path feature/other)"
[[ "$got" = "$tmp/org/demo-worktrees/feature-other" ]] ||
  fail "path entered via a symlink was not the physical path: $got"

# An exported GIT_DIR from somewhere else must not make the cwd a work tree.
# rev-parse honours GIT_DIR over discovery, so from a directory with no .git
# and GIT_DIR naming the demo repository, --show-toplevel returned the cwd and
# the script invented a parent beside it, exit 0. Found by the review of #83,
# pre-existing on main, filed as #94.
elsewhere="$tmp/elsewhere"
mkdir -p "$elsewhere"
status=0
out="$(cd "$elsewhere" && GIT_DIR="$repo/.git" "$WT" path some/branch 2>/dev/null)" || status=$?
[[ "$status" -ne 0 ]] ||
  fail "path with an exported GIT_DIR exited 0 and printed: $out"
[[ -z "$out" ]] ||
  fail "path with an exported GIT_DIR invented a location: $out"
# ...and inside the repository an exported GIT_DIR changes nothing.
got="$(cd "$repo" && GIT_DIR="$repo/.git" GIT_WORK_TREE="$repo" "$WT" path feature/other)"
[[ "$got" = "$tmp/org/demo-worktrees/feature-other" ]] ||
  fail "path inside the repository with GIT_DIR exported was wrong: $got"

echo "worktree tests: passed"
