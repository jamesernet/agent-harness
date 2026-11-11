#!/usr/bin/env bash
set -euo pipefail

# Sibling worktrees for parallel agent sessions: one worktree per brief/issue,
# one Claude Code / Codex session per worktree, no branch-switching collisions.
#
#   worktree.sh new <branch> [start-point]   create <repo>-worktrees/<slug> for <branch>
#                                            (branch is created from start-point,
#                                            default HEAD, if it doesn't exist)
#   worktree.sh ls                           list this repo's worktrees
#   worktree.sh rm <branch>                  remove the worktree (branch is kept)
#   worktree.sh path <branch>                print the worktree path and exit
#
# `path` exists so a shell wrapper can cd into a new worktree without
# recomputing the layout. A subprocess cannot change its parent's directory, so
# `new` can only ever tell you where it put things — see the `wt` function in
# workstation's config/zsh/functions.zsh, which uses this to do the cd for you.
# Keeping the computation here means the wrapper cannot drift from the script.
#
# Run from anywhere inside the target repo. Worktrees live NEXT TO the repo
# (…/<org>/<repo>-worktrees/<slug>), never inside it. Slug = branch with
# "/" flattened to "-". The pre-commit branch backstop lives in the main
# repo's .git and applies to every worktree automatically.

usage() {
  grep '^#   ' "$0" | sed 's/^#  //'
  exit 1
}

cmd="${1:-}"

# Where the MAIN checkout is. Every subcommand lays worktrees out beside it, so
# it is resolved once, here, and asserted rather than inferred.
#
# --show-toplevel is the work-tree assertion. Outside a repository and in a bare
# one it is fatal, and a bare `var=$(...)` is the form `set -e` tracks, so the
# script stops with git's own message and exit 128 instead of printing a path it
# invented. It is also the right answer wherever the tree we stand in IS the
# main checkout: the primary, any subdirectory of it, and a submodule's own
# checkout -- where the shared git dir is <outer>/.git/modules/<sub>, and
# `dirname` of it would have put the worktrees INSIDE the superproject's .git.
#
# A linked worktree is the one place --show-toplevel is wrong, because it names
# the worktree we are standing in. It is recognised the way build-adapters.sh
# and this repo's pre-commit.local recognise it: the per-worktree git dir and
# the shared one are different directories. Only then is the main checkout
# taken from the shared .git, and only when that directory is literally named
# ".git". A linked worktree of a submodule, or of a repository made with
# --separate-git-dir, has no checkout at `dirname`, so it is refused by name.
#
# Physical paths (pwd -P) throughout: git records worktrees as /private/var on
# macOS while $TMPDIR says /var, and `git worktree remove` matches the recorded
# spelling. --show-toplevel is already realpath'd by git; --git-common-dir is
# RELATIVE from the primary (".git", "../.git"), hence the cd. Each cd is its
# own bare assignment so a failure is visible to set -e, not swallowed inside a
# larger string.
toplevel="$(git rev-parse --show-toplevel)"
git_dir="$(git rev-parse --git-dir)"
git_dir="$(cd "$git_dir" && pwd -P)"
common_dir="$(git rev-parse --git-common-dir)"
common_dir="$(cd "$common_dir" && pwd -P)"
if [[ "$git_dir" == "$common_dir" ]]; then
  root="$toplevel"
elif [[ "$(basename "$common_dir")" == .git ]]; then
  root="$(dirname "$common_dir")"
else
  cat >&2 <<EOF
worktree.sh: refusing to lay out worktrees from here.

  standing in:    $toplevel (a linked worktree)
  shared git dir: $common_dir

That directory is not a ".git" beside a checkout, so there is no main checkout
to put worktrees next to: this is a linked worktree of a submodule, or of a
repository created with --separate-git-dir. Run from the primary checkout.
EOF
  exit 1
fi
repo="$(basename "$root")"
wt_root="$(dirname "$root")/$repo-worktrees"

# Worktree parents were written "<repo>.worktrees" here while every repo-local
# helper and the rest of the estate used "<repo>-worktrees". The hyphen won, so
# new worktrees go there. The ones already on disk under the dot are still
# resolved for `path` and `rm`, which is what lets them drain instead of needing
# a migration: a worktree is short-lived, so the dot parents empty on their own.
wt_root_legacy="$(dirname "$root")/$repo.worktrees"

# Where an existing worktree for <slug> actually is: the hyphen, unless only the
# legacy dot copy is on disk.
wt_resolve() {
  if [ ! -e "$wt_root/$1" ] && [ -e "$wt_root_legacy/$1" ]; then
    echo "$wt_root_legacy/$1"
  else
    echo "$wt_root/$1"
  fi
}

case "$cmd" in
  new)
    branch="${2:?usage: worktree.sh new <branch> [start-point]}"
    slug="${branch//\//-}"
    path="$wt_root/$slug"
    mkdir -p "$wt_root"
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      git worktree add "$path" "$branch"
    else
      git worktree add -b "$branch" "$path" "${3:-HEAD}"
    fi
    echo
    echo "worktree ready: $path"
    echo "next: cd \"$path\" and start the agent session there."
    ;;
  ls)
    git worktree list
    ;;
  path)
    branch="${2:?usage: worktree.sh path <branch>}"
    slug="${branch//\//-}"
    wt_resolve "$slug"
    ;;
  rm)
    branch="${2:?usage: worktree.sh rm <branch>}"
    slug="${branch//\//-}"
    path="$(wt_resolve "$slug")"
    git worktree remove "$path"
    echo "removed $path (branch \"$branch\" kept — git branch -d when merged)"
    ;;
  *)
    usage
    ;;
esac
