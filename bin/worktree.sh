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
# Anchor to the MAIN checkout, not the current one. --show-toplevel returns the
# worktree you are standing in, so running this from inside a worktree computed
# a parent nested under that worktree. --git-common-dir points at the main
# checkout's .git from any worktree, and resolves from any subdirectory.
root="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
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
