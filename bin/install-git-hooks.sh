#!/usr/bin/env bash
set -euo pipefail

# Installs the local git backstop (bin/git-hooks/pre-commit) into repos so that
# commits on main/master are blocked regardless of who or what is committing.
# This is the everywhere-backstop for the "branch before you build" rule — the
# Claude PreToolUse hook only covers Claude; this covers Codex and humans too.
#
#   bin/install-git-hooks.sh                 install into the default REPOS below
#   bin/install-git-hooks.sh <repo> [repo…]  install into specific repos
#
# Middle-path install (safe for client repos):
#   - If the repo already has a pre-commit hook that isn't ours, it's preserved
#     as pre-commit.local, and our hook execs it after the branch check passes —
#     the repo's own checks keep running.
#   - Re-running is idempotent: our hook is recognised by its "llmctx-hook"
#     marker and simply refreshed in place.
#   - Repos where a hook framework has set core.hooksPath (husky, lefthook) are
#     SKIPPED with a warning: copying into .git/hooks there would be silently
#     inert. Add the branch check through that framework's config instead.
#
# The hook is copied into each repo's git hooks dir (local, not committed).
# Re-run after cloning a repo fresh. Linked worktrees share the main repo's
# hooks, so installing once covers all of a repo's worktrees.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SRC="$SCRIPT_DIR/git-hooks/pre-commit"
POLICY_LIB_SRC="$SCRIPT_DIR/lib/policy.sh"
MARKER="llmctx-hook"

REPOS=(
  "$HOME/repos/github.com/jamesernet/agent-harness"
  "$HOME/repos/github.com/emergentlabs/jamesernet.com"
  "$HOME/repos/github.com/emergentlabs/emergentlabs.xyz"
)
if [ "$#" -gt 0 ]; then REPOS=("$@"); fi

for repo in "${REPOS[@]}"; do
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    echo "skip: $repo (not a git repo)"
    continue
  fi

  hooks_path="$(git -C "$repo" config --get core.hooksPath || true)"
  if [ -n "$hooks_path" ]; then
    echo "skip: $repo (core.hooksPath=$hooks_path — a hook framework manages hooks here;" >&2
    echo "      add the branch check via that framework's config instead)" >&2
    continue
  fi

  hooks_dir="$(git -C "$repo" rev-parse --git-path hooks)"
  case "$hooks_dir" in /*) ;; *) hooks_dir="$repo/$hooks_dir" ;; esac
  mkdir -p "$hooks_dir"
  existing="$hooks_dir/pre-commit"

  # Ours = new marker, or the pre-marker version of this same hook (so
  # upgrading doesn't preserve a stale copy of ourselves as pre-commit.local).
  if [ -f "$existing" ] && ! grep -qE "$MARKER|Installed by llm-context" "$existing"; then
    if [ -e "$hooks_dir/pre-commit.local" ]; then
      echo "skip: $repo (has both a foreign pre-commit AND pre-commit.local — resolve manually)" >&2
      continue
    fi
    mv "$existing" "$hooks_dir/pre-commit.local"
    chmod +x "$hooks_dir/pre-commit.local"
    echo "preserved: existing pre-commit -> pre-commit.local (chained after branch check) in $repo"
  fi

  cp "$HOOK_SRC" "$existing"
  chmod +x "$existing"
  cp "$POLICY_LIB_SRC" "$hooks_dir/llmctx-policy.sh"
  chmod 0644 "$hooks_dir/llmctx-policy.sh"
  echo "installed pre-commit -> $repo"
done
