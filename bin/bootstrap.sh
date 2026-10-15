#!/usr/bin/env bash
set -euo pipefail

# One-command setup on a new machine (after cloning this repo):
#   bin/bootstrap.sh
#   bin/bootstrap.sh --account <name>    just one Claude account
#
# 1. installs versioned copies of all skills (skills/ + vendor/) into
#    <account>/skills and ~/.codex/skills
# 2. installs the branch backstop + this repo's own pre-commit checks
#    (lint-skills + build-adapters --check) into THIS repo's .git/hooks
# 3. builds the tool adapters (<account>/CLAUDE.md, ~/.codex/AGENTS.md)
#    and installs the versioned <account>/settings.json
#
# <account> is every registered Claude config directory, always including
# ~/.claude. See bin/lib/accounts.sh and `llmctx account list`.
#
# ADAPTERS GO LAST, AND A FAILURE THERE DOES NOT ABORT THE REST. They used to run
# first, under `set -e`, so build-adapters.sh refusing to install from a linked
# worktree exited here with the branch backstop and every skill NOT installed --
# while the error text talked only about CLAUDE.md @import paths. A guard that
# leaves you less protected than before, reporting a different problem, is the
# wrong trade. Now the backstop is in place before adapters are attempted, and
# the summary below names what did not happen.
#
# Not covered here (per-repo, run where needed):
#   bin/install-git-hooks.sh   pre-commit branch protection for other repos

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

"$SCRIPT_DIR/install-skills.sh" "$@"

"$SCRIPT_DIR/install-git-hooks.sh" "$SRC"
hooks_dir="$(git -C "$SRC" rev-parse --git-path hooks)"
case "$hooks_dir" in /*) ;; *) hooks_dir="$SRC/$hooks_dir" ;; esac
cp "$SCRIPT_DIR/git-hooks/pre-commit-local.agent-harness" "$hooks_dir/pre-commit.local"
chmod +x "$hooks_dir/pre-commit.local"
echo "installed pre-commit.local (skill lint + adapter drift check) -> $SRC"

adapter_status=0
"$SCRIPT_DIR/build-adapters.sh" "$@" || adapter_status=$?

echo
if ((adapter_status != 0)); then
  echo "bootstrap INCOMPLETE: build-adapters.sh exited $adapter_status." >&2
  echo "  installed:     skills, the branch backstop, this repo's pre-commit.local" >&2
  echo "  NOT installed: <account>/CLAUDE.md, <account>/settings.json, ~/.codex/AGENTS.md" >&2
  echo "  the adapter error above says what to do; re-run bin/build-adapters.sh to finish." >&2
  exit "$adapter_status"
fi

echo "bootstrap complete. per-repo git hooks: bin/install-git-hooks.sh in each repo."
