#!/usr/bin/env bash
set -euo pipefail

# One-command setup on a new machine (after cloning this repo):
#   bin/bootstrap.sh
#   bin/bootstrap.sh --account <name>    just one Claude account
#
# 1. installs versioned copies of all skills (skills/ + vendor/) into
#    every registered Claude and Codex account's skills directory
# 2. installs the branch backstop + this repo's own pre-commit checks
#    (lint-skills + build-adapters --check) into THIS repo's .git/hooks
# 2b. installs managed agents into <account>/agents (a conflict is reported,
#    not fatal)
# 3. builds the tool adapters (<claude-home>/CLAUDE.md,
#    <codex-home>/AGENTS.md)
#    and installs the versioned <account>/settings.json
#
# Default homes are always included; additional homes come from the provider
# registries. See bin/lib/accounts.sh and `llmctx account list --provider ...`.
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
bootstrap_args=("$@")

# EVERY INDEPENDENT STEP RUNS, AND THE SUMMARY NAMES WHAT FAILED. Skills used to
# run first under set -e, so two skill directories with the wrong owner (#36's
# recurrence) stopped bootstrap before the branch backstop, this repo's local
# checks, the agents and the adapters -- on the day the policy library had
# changed and the git hook genuinely needed refreshing (#104). A disputed skill
# directory is a conflict to name loudly and fail the exit code on; it is not
# a reason to leave the repository without its guard. The hooks do not depend
# on the skills directory at all.
skills_status=0
"$SCRIPT_DIR/install-skills.sh" "$@" || skills_status=$?

hooks_status=0
"$SCRIPT_DIR/install-git-hooks.sh" "$SRC" || hooks_status=$?
hooks_dir="$(git -C "$SRC" rev-parse --git-path hooks)"
case "$hooks_dir" in /*) ;; *) hooks_dir="$SRC/$hooks_dir" ;; esac
# pre-commit.local is the slot install-git-hooks.sh PRESERVES a foreign hook
# into, and the slot this repository's own checks occupy. The line above can
# therefore have just written a husky or lefthook hook there and printed
# "preserved:", and an unconditional cp here destroyed it four lines later,
# exit 0 (#57). The file is overwritten only when it is ours: the marker, or
# the pre-marker header of this same file, so an upgrade still refreshes it.
local_hook="$hooks_dir/pre-commit.local"
local_hook_status=0
# Line 2 must BE the marker line, or the pre-marker header line, exactly. An
# unanchored grep let a foreign hook that merely MENTIONED either phrase read
# as ours and be overwritten -- the review of this change reproduced it with a
# husky hook whose second line said "NOT agent-harness ITSELF" -- and a
# substring test on line 2 alone has the same hole. Equality does not.
local_hook_line2=""
[ ! -f "$local_hook" ] || local_hook_line2="$(sed -n '2p' "$local_hook")"
case "$local_hook_line2" in
  '# llmctx-local-checks' | '# Repo-local pre-commit checks for agent-harness ITSELF. Installed as') local_hook_ours=1 ;;
  *) local_hook_ours=0 ;;
esac
if [ -f "$local_hook" ] && [ "$local_hook_ours" -eq 0 ]; then
  local_hook_status=1
  echo "bootstrap: NOT overwriting $local_hook" >&2
  echo "  it is not this repository's local-checks hook; install-git-hooks.sh preserves a" >&2
  echo "  foreign pre-commit there and the branch backstop chains to it. Move it aside, or" >&2
  echo "  fold its checks into bin/git-hooks/pre-commit-local.agent-harness, then re-run." >&2
else
  cp "$SCRIPT_DIR/git-hooks/pre-commit-local.agent-harness" "$local_hook"
  chmod +x "$local_hook"
  echo "installed pre-commit.local (skill lint + adapter drift check) -> $SRC"
fi

# Agents install AFTER the backstop and never abort it: a hand-written
# ~/.claude/agents/reviewer.md is a conflict, not a reason to leave the repo
# without its branch guard. Only the flags it understands are forwarded —
# --bundle belongs to skills, and an unknown flag here used to exit 2 and stop
# everything that followed.
agent_args=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dev) agent_args+=("$1") ;;
    --account)
      agent_args+=("$1" "${2:-}")
      shift
      ;;
    --account=*) agent_args+=("$1") ;;
  esac
  shift
done
# ${arr[@]+"${arr[@]}"}: an empty array is an unbound variable under set -u in
# bash 3.2, which is what macOS ships and the CI runner uses.
set -- ${bootstrap_args[@]+"${bootstrap_args[@]}"}
agents_status=0
"$SCRIPT_DIR/install-agents.sh" ${agent_args[@]+"${agent_args[@]}"} || agents_status=$?

adapter_status=0
"$SCRIPT_DIR/build-adapters.sh" "$@" || adapter_status=$?

echo
failed=0
if ((skills_status != 0)); then
  failed=$((failed + 1))
  echo "bootstrap: install-skills.sh exited $skills_status; the skills named 'conflict:' above were NOT installed." >&2
  echo "  each is a directory agent-harness does not own; decide per skill (see issue #36), then re-run bin/llmctx skills install." >&2
fi
if ((hooks_status != 0)); then
  failed=$((failed + 1))
  echo "bootstrap: install-git-hooks.sh exited $hooks_status; the branch backstop for this repository was NOT refreshed." >&2
fi
if ((local_hook_status != 0)); then
  failed=$((failed + 1))
  echo "bootstrap: this repository's pre-commit.local was NOT installed; a foreign hook occupies the slot (see above)." >&2
fi
if ((agents_status != 0)); then
  failed=$((failed + 1))
  echo "bootstrap: install-agents.sh exited $agents_status; the agents above were not all installed." >&2
  echo "  resolve the conflict named, then re-run bin/install-agents.sh." >&2
fi
if ((adapter_status != 0)); then
  failed=$((failed + 1))
  echo "bootstrap INCOMPLETE: build-adapters.sh exited $adapter_status." >&2
  echo "  NOT installed: Claude adapters/settings or Codex AGENTS.md files" >&2
  echo "  the adapter error above says what to do; re-run bin/build-adapters.sh to finish." >&2
  exit "$adapter_status"
fi
if ((failed != 0)); then
  echo "bootstrap finished with $failed step(s) failed (named above); everything else is installed." >&2
  exit 1
fi

echo "bootstrap complete. per-repo git hooks: bin/install-git-hooks.sh in each repo."
