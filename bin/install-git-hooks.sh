#!/usr/bin/env bash
set -euo pipefail

# Installs the local git backstop (bin/git-hooks/pre-commit) into repos so that
# commits on main/master are blocked regardless of who or what is committing.
# This is the everywhere-backstop for the "branch before you build" rule — the
# Claude PreToolUse hook only covers Claude; this covers Codex and humans too.
#
#   bin/install-git-hooks.sh                 install into the built-in repos
#                                            plus every registered one
#   bin/install-git-hooks.sh <repo> [repo…]  install into specific repos
#
# Per repository it says what it did -- `current:` (hook and policy library
# already match this checkout), `refreshed:` (one or both had fallen behind;
# which is named), `installed pre-commit ->` (there was none), `preserved:`
# (a foreign hook moved aside first), or `skip:` with the reason -- and ends
# with one summary line. A `refreshed:` line is a guard that had silently
# stopped matching the policy it enforces, which is the state nothing reported
# before (#85): the hook lives in .git/, which is never cloned, so staleness is
# the default over time, and the no-argument run is the estate's refresh.
#
# Registering a repo (machine state, so global config, beside llmctx.skillBundle):
#
#   git config --global --add llmctx.repo ~/repos/github.com/<org>/<repo>
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
# A contract between two repositories, frozen the way the `llmctx` identifier
# is. project-scaffold writes a placeholder at .git/hooks/pre-commit whose whole
# body is `exec pre-commit.local`, so a repository's committed guard runs before
# this installer has been near it; its header carries this string and says this
# installer owns the path and will replace the file. Without recognising it the
# shim read as foreign, the preservation branch found pre-commit.local already
# present, and the install took the hard skip below -- so the handoff both
# tools documented never happened and the repository got no policy resolution
# at all (#59). Nothing is lost by replacing it: our hook chains to
# pre-commit.local, which is the only thing the shim did.
SHIM_MARKER="scaffold-hook-shim"

REPOS=(
  "$HOME/repos/github.com/jamesernet/agent-harness"
  "$HOME/repos/github.com/emergentlabs/jamesernet.com"
  "$HOME/repos/github.com/emergentlabs/emergentlabs.xyz"
)

# The hook lives in .git/, which is never cloned, so a repo nothing names loses
# the backstop the moment it is cloned fresh — silently, because a missing hook
# looks exactly like a repo that was never meant to have one. The registry is
# how a repo says it wants the backstop without this file having to know the
# whole estate.
#
# Registration is additive, for the same reason the account registry is: a list
# that could omit the three above would reintroduce the failure it exists to
# prevent — an install that skips a repo and still reports success.
while IFS= read -r registered; do
  [ -n "$registered" ] || continue
  # shellcheck disable=SC2088  # matching a LITERAL tilde is the point here
  case "$registered" in
    '~') registered="$HOME" ;;
    '~/'*) registered="$HOME/${registered#'~/'}" ;;
  esac
  while [[ "$registered" == */ && "$registered" != / ]]; do registered="${registered%/}"; done
  dup=0
  for known in "${REPOS[@]}"; do
    if [ "$known" = "$registered" ]; then
      dup=1
      break
    fi
  done
  if [ "$dup" -eq 0 ]; then REPOS+=("$registered"); fi
done < <(git config --global --get-all llmctx.repo 2>/dev/null || true)

# An explicit list is exactly that: neither the built-ins nor the registry.
if [ "$#" -gt 0 ]; then REPOS=("$@"); fi

n_current=0 n_refreshed=0 n_installed=0 n_skipped=0
for repo in "${REPOS[@]}"; do
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    echo "skip: $repo (not a git repo)"
    n_skipped=$((n_skipped + 1))
    continue
  fi

  hooks_path="$(git -C "$repo" config --get core.hooksPath || true)"
  if [ -n "$hooks_path" ]; then
    echo "skip: $repo (core.hooksPath=$hooks_path — a hook framework manages hooks here;" >&2
    echo "      add the branch check via that framework's config instead)" >&2
    n_skipped=$((n_skipped + 1))
    continue
  fi

  hooks_dir="$(git -C "$repo" rev-parse --git-path hooks)"
  case "$hooks_dir" in /*) ;; *) hooks_dir="$repo/$hooks_dir" ;; esac
  mkdir -p "$hooks_dir"
  existing="$hooks_dir/pre-commit"

  # Ours = new marker, the pre-marker version of this same hook (so upgrading
  # doesn't preserve a stale copy of ourselves as pre-commit.local), or the
  # scaffold's placeholder, which exists to be replaced by this.
  if [ -f "$existing" ] && ! grep -qE "$MARKER|Installed by llm-context|$SHIM_MARKER" "$existing"; then
    if [ -e "$hooks_dir/pre-commit.local" ]; then
      echo "skip: $repo (has both a foreign pre-commit AND pre-commit.local — resolve manually)" >&2
      n_skipped=$((n_skipped + 1))
      continue
    fi
    mv "$existing" "$hooks_dir/pre-commit.local"
    chmod +x "$hooks_dir/pre-commit.local"
    echo "preserved: existing pre-commit -> pre-commit.local (chained after branch check) in $repo"
  fi

  # What this run changes, named before it changes it. Ours-and-identical is
  # `current` and nothing is written; ours-and-different is `refreshed`, with
  # the half that had fallen behind named; anything else is `installed`.
  outcome=installed
  if [ -f "$existing" ] && grep -q "$MARKER" "$existing"; then
    stale=""
    cmp -s "$HOOK_SRC" "$existing" || stale="hook"
    if ! cmp -s "$POLICY_LIB_SRC" "$hooks_dir/llmctx-policy.sh"; then
      stale="${stale:+$stale, }policy library"
    fi
    if [ -z "$stale" ]; then
      outcome=current
    else
      outcome="refreshed ($stale)"
    fi
  fi
  if [ "$outcome" = current ]; then
    echo "current: $repo"
    n_current=$((n_current + 1))
    continue
  fi

  cp "$HOOK_SRC" "$existing"
  chmod +x "$existing"
  cp "$POLICY_LIB_SRC" "$hooks_dir/llmctx-policy.sh"
  chmod 0644 "$hooks_dir/llmctx-policy.sh"
  case "$outcome" in
    installed)
      echo "installed pre-commit -> $repo"
      n_installed=$((n_installed + 1))
      ;;
    *)
      echo "refreshed: $repo ${outcome#refreshed }"
      n_refreshed=$((n_refreshed + 1))
      ;;
  esac
done
echo "git hooks: $n_current current, $n_refreshed refreshed, $n_installed installed, $n_skipped skipped"
