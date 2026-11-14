#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$SRC/bin/llmctx"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-repo-diff-test.XXXXXX")"
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q
export GIT_CONFIG_GLOBAL="$tmp/global.gitconfig"

fail() {
  echo "repo diff test failed: $*" >&2
  exit 1
}

if "$CLI" repo diff "$repo" --json >"$tmp/missing.json"; then
  fail "empty repository was reported compliant"
fi
jq -e '.compliant == false and any(.findings[]; .status == "MISSING")' "$tmp/missing.json" >/dev/null ||
  fail "missing findings were not reported"

printf '%s\n' '{"schemaVersion":1,"profile":"client"}' >"$repo/.llmctx.json"
printf '%s\n' '# Project instructions' >"$repo/AGENTS.md"
printf '%s\n' '# Claude' '' '@AGENTS.md' >"$repo/CLAUDE.md"
mkdir -p "$repo/docs/briefs"
printf '%s\n' '# Briefs' >"$repo/docs/briefs/README.md"
"$SRC/bin/install-git-hooks.sh" "$repo" >/dev/null

"$CLI" repo diff "$repo" --json >"$tmp/compliant.json" || fail "configured repository was not compliant"
jq -e '.compliant == true' "$tmp/compliant.json" >/dev/null || fail "compliant JSON was false"

git -C "$repo" config --local llmctx.branchPolicy off
"$CLI" repo diff "$repo" --json >"$tmp/override.json" || fail "intentional override failed"
jq -e 'any(.findings[]; .id == "branch-policy" and .status == "OVERRIDE")' "$tmp/override.json" >/dev/null ||
  fail "local override was not identified"

hooks_dir="$(git -C "$repo" rev-parse --git-path hooks)"
case "$hooks_dir" in /*) ;; *) hooks_dir="$repo/$hooks_dir" ;; esac
printf '%s\n' '# stale' >>"$hooks_dir/pre-commit"
if "$CLI" repo diff "$repo" --json >"$tmp/stale.json"; then
  fail "stale hook was reported compliant"
fi
jq -e 'any(.findings[]; .id == "git-hook" and .status == "STALE")' "$tmp/stale.json" >/dev/null ||
  fail "stale hook was not identified"

# --- declarable conventions ------------------------------------------------
#
# Both defaults are unchanged above; these assert the opt-outs, and that a
# `false` value is distinguishable from an absent one. jq's `//` yields its
# right-hand side for false as well as null, which made `"claudeImport": false`
# read back as unset and do nothing at all.

decl="$tmp/decl"
rm -rf "$decl" && mkdir -p "$decl"
git -C "$decl" init -q -b main
git -C "$decl" checkout -q -b feature/t
printf '%s\n' '# Project instructions' >"$decl/AGENTS.md"
"$SRC/bin/install-git-hooks.sh" "$decl" >/dev/null

printf '%s\n' '{"schemaVersion":1,"profile":"personal"}' >"$decl/.llmctx.json"
"$CLI" repo diff "$decl" --json >"$tmp/undeclared.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "briefs" and .status == "MISSING")' "$tmp/undeclared.json" >/dev/null ||
  fail "briefs default is no longer enforced"
jq -e 'any(.findings[]; .id == "claude-import" and .status == "MISSING")' "$tmp/undeclared.json" >/dev/null ||
  fail "claude-import default is no longer enforced"

printf '%s\n' '{"schemaVersion":1,"profile":"personal","briefs":"tracker","claudeImport":false}' >"$decl/.llmctx.json"
"$CLI" repo diff "$decl" --json >"$tmp/declared.json" || fail "declared opt-outs did not make the repository compliant"
jq -e 'any(.findings[]; .id == "briefs" and .status == "OVERRIDE")' "$tmp/declared.json" >/dev/null ||
  fail "briefs=tracker was not recorded as an override"
jq -e 'any(.findings[]; .id == "claude-import" and .status == "OVERRIDE")' "$tmp/declared.json" >/dev/null ||
  fail "claudeImport=false was not recorded as an override (jq // treats false as absent)"

# --- core.hooksPath must not read as compliant ------------------------------
#
# The regression this guards: git-hook returned UNKNOWN, the policy-library
# check was skipped entirely, and a repository with no branch enforcement at all
# printed "Result: compliant".

hp="$tmp/hookspath"
rm -rf "$hp" && mkdir -p "$hp/.githooks"
git -C "$hp" init -q -b main
git -C "$hp" checkout -q -b feature/t
git -C "$hp" config core.hooksPath .githooks
printf '%s\n' '# Project instructions' >"$hp/AGENTS.md"
printf '%s\n' '# Claude' '' '@AGENTS.md' >"$hp/CLAUDE.md"
mkdir -p "$hp/docs/briefs" && printf '%s\n' '# Briefs' >"$hp/docs/briefs/README.md"
printf '%s\n' '{"schemaVersion":1,"profile":"personal"}' >"$hp/.llmctx.json"

"$CLI" repo diff "$hp" --json >"$tmp/hp-empty.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "policy-enforcement" and .status == "MISSING")' "$tmp/hp-empty.json" >/dev/null ||
  fail "core.hooksPath with no branch check was not reported"

printf '%s\n' '#!/bin/sh' 'git symbolic-ref --short HEAD' >"$hp/.githooks/pre-commit"
"$CLI" repo diff "$hp" --json >"$tmp/hp-own.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "policy-enforcement" and .status == "UNKNOWN")' "$tmp/hp-own.json" >/dev/null ||
  fail "a foreign branch check was not distinguished from none at all"

# --- a repository that owns a stricter hook can say so (#118) ----------------
#
# Declared as `"hooks": "repo-owned"`. git-hook becomes OVERRIDE, and
# policy-enforcement becomes OVERRIDE only when the evidence grep still finds a
# branch check in that directory. A declaration can never hide the absence of
# enforcement, and a misspelt value is heard rather than silently dropped.
jq -e 'any(.findings[]; .id == "git-hook" and .status == "UNKNOWN")' "$tmp/hp-own.json" >/dev/null ||
  fail "undeclared core.hooksPath no longer reports git-hook UNKNOWN"

git -C "$hp" add .githooks/pre-commit # repo-owned means committed: the index is the test
printf '%s\n' '{"schemaVersion":1,"profile":"personal","hooks":"repo-owned"}' >"$hp/.llmctx.json"
"$CLI" repo diff "$hp" --json >"$tmp/hp-declared.json" ||
  fail "a declared repo-owned hook with a branch check was not compliant: $(jq -c '[.findings[] | select(.status != "OK")]' "$tmp/hp-declared.json")"
jq -e 'any(.findings[]; .id == "git-hook" and .status == "OVERRIDE" and (.actual | test("\\.githooks")))' "$tmp/hp-declared.json" >/dev/null ||
  fail "a declared repo-owned hook was not recorded as an override on git-hook: $(jq -c '[.findings[] | select(.id == "git-hook")]' "$tmp/hp-declared.json")"
jq -e 'any(.findings[]; .id == "policy-enforcement" and .status == "OVERRIDE")' "$tmp/hp-declared.json" >/dev/null ||
  fail "a declared repo-owned branch check was not recorded as an override on policy-enforcement: $(jq -c '[.findings[] | select(.id == "policy-enforcement")]' "$tmp/hp-declared.json")"
jq -e '.compliant == true' "$tmp/hp-declared.json" >/dev/null ||
  fail "the motivating repository did not report compliant once declared"

# Declared, but the hook checks no branch: ownership is honoured, the absence
# of enforcement is still MISSING, and the run is non-compliant.
printf '%s\n' '#!/bin/sh' 'echo docs build' >"$hp/.githooks/pre-commit"
"$CLI" repo diff "$hp" --json >"$tmp/hp-declared-none.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "policy-enforcement" and .status == "MISSING")' "$tmp/hp-declared-none.json" >/dev/null ||
  fail "a declaration hid the absence of a branch check"
jq -e '.compliant == false' "$tmp/hp-declared-none.json" >/dev/null ||
  fail "a declared hook with no branch check was reported compliant"

# Declared, but the directory core.hooksPath names does not exist: MISSING as
# before, and git-hook does not claim an override over a directory that is not there.
rm -rf "$hp/.githooks"
"$CLI" repo diff "$hp" --json >"$tmp/hp-declared-missing.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "policy-enforcement" and .status == "MISSING" and (.actual | test("does not exist")))' "$tmp/hp-declared-missing.json" >/dev/null ||
  fail "a declaration hid a missing hooks directory"
jq -e 'any(.findings[]; .id == "git-hook" and .status == "UNKNOWN")' "$tmp/hp-declared-missing.json" >/dev/null ||
  fail "git-hook claimed an override over a hooks directory that does not exist"

# A misspelt or non-string value is a hooks-owner CONFLICT from repo diff
# itself, never a failed policy resolve: the managed hooks skip their branch
# check when policy does not resolve, so a key only this checker reads must not
# be able to switch the guard off. Both rows stay UNKNOWN, as if undeclared.
mkdir -p "$hp/.githooks" && printf '%s\n' '#!/bin/sh' 'git symbolic-ref --short HEAD' >"$hp/.githooks/pre-commit"
for bad in '"repo-ownd"' 'false'; do
  printf '{"schemaVersion":1,"profile":"personal","hooks":%s}\n' "$bad" >"$hp/.llmctx.json"
  "$CLI" repo diff "$hp" --json >"$tmp/hp-bad.json" 2>/dev/null || true
  jq -e 'any(.findings[]; .id == "hooks-owner" and .status == "CONFLICT" and (.actual | test("invalid hooks")))' "$tmp/hp-bad.json" >/dev/null ||
    fail "hooks=$bad was not reported as a hooks-owner CONFLICT: $(jq -c '[.findings[] | select(.id == "hooks-owner" or .id == "policy")]' "$tmp/hp-bad.json")"
  if jq -e 'any(.findings[]; .id == "policy")' "$tmp/hp-bad.json" >/dev/null; then
    fail "hooks=$bad failed the policy resolve, which would switch the managed hooks off"
  fi
  jq -e 'any(.findings[]; .id == "git-hook" and .status == "UNKNOWN")' "$tmp/hp-bad.json" >/dev/null ||
    fail "hooks=$bad was treated as a declaration"
  jq -e 'any(.findings[]; .id == "policy-enforcement" and .status == "UNKNOWN")' "$tmp/hp-bad.json" >/dev/null ||
    fail "hooks=$bad flipped policy-enforcement to an override"
  jq -e '.compliant == false' "$tmp/hp-bad.json" >/dev/null || fail "hooks=$bad was reported compliant"
done

# null reads as unset, as it does for briefs and claudeImport.
printf '%s\n' '{"schemaVersion":1,"profile":"personal","hooks":null}' >"$hp/.llmctx.json"
"$CLI" repo diff "$hp" --json >"$tmp/hp-null.json" 2>/dev/null || true
if jq -e 'any(.findings[]; .id == "hooks-owner")' "$tmp/hp-null.json" >/dev/null; then
  fail "hooks=null was not read as unset: $(jq -c '[.findings[] | select(.id == "hooks-owner")]' "$tmp/hp-null.json")"
fi
jq -e 'any(.findings[]; .id == "git-hook" and .status == "UNKNOWN")' "$tmp/hp-null.json" >/dev/null ||
  fail "hooks=null changed the undeclared report"

# An explicit managed in a clone whose core.hooksPath is set is the mirror
# contradiction: git runs that framework, not the managed backstop.
printf '%s\n' '{"schemaVersion":1,"profile":"personal","hooks":"managed"}' >"$hp/.llmctx.json"
"$CLI" repo diff "$hp" --json >"$tmp/hp-managed-set.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "hooks-owner" and .status == "CONFLICT" and (.actual | test("hooks=managed")))' "$tmp/hp-managed-set.json" >/dev/null ||
  fail "an explicit managed declaration over core.hooksPath was not reported: $(jq -c '[.findings[] | select(.id == "hooks-owner")]' "$tmp/hp-managed-set.json")"
jq -e '.compliant == false' "$tmp/hp-managed-set.json" >/dev/null ||
  fail "an explicit managed declaration over core.hooksPath was reported compliant"
jq -e 'any(.findings[]; .id == "hooks-owner" and (.actual | test("\\(local config\\)")) and (.remediation | test("--local --unset")))' "$tmp/hp-managed-set.json" >/dev/null ||
  fail "the managed contradiction did not name the scope the value came from: $(jq -c '[.findings[] | select(.id == "hooks-owner")]' "$tmp/hp-managed-set.json")"
jq -e 'any(.findings[]; .id == "git-hook" and .status == "UNKNOWN" and .remediation == "")' "$tmp/hp-managed-set.json" >/dev/null ||
  fail "git-hook offered a second, contradictory fix beside the hooks-owner row: $(jq -c '[.findings[] | select(.id == "git-hook")]' "$tmp/hp-managed-set.json")"

# Not JSON at all: the report still prints, carrying the CONFLICT the resolver
# produced, instead of `declared` aborting the run under set -e with no output.
printf '%s\n' '{bad' >"$hp/.llmctx.json"
"$CLI" repo diff "$hp" --json >"$tmp/hp-badjson.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "policy" and .status == "CONFLICT" and (.actual | test("invalid JSON")))' "$tmp/hp-badjson.json" >/dev/null ||
  fail "invalid JSON in .llmctx.json produced no report: $(head -c 200 "$tmp/hp-badjson.json")"

# core.hooksPath may be written with a tilde. git expands it when it runs the
# hooks, so the checker has to, or a directory that exists reads as missing.
# HOME is the repository here, so the expanded directory is inside it and the
# declaration is honoured; a tilde that lands outside is the global case below.
printf '%s\n' '{"schemaVersion":1,"profile":"personal","hooks":"repo-owned"}' >"$hp/.llmctx.json"
# shellcheck disable=SC2088 # the literal tilde is the case: git stores it unexpanded and expands it at run time
git -C "$hp" config core.hooksPath '~/.githooks'
HOME="$hp" "$CLI" repo diff "$hp" --json >"$tmp/hp-tilde.json" ||
  fail "a tilde core.hooksPath was not expanded: $(jq -c '[.findings[] | select(.status != "OK")]' "$tmp/hp-tilde.json")"
jq -e 'any(.findings[]; .id == "git-hook" and .status == "OVERRIDE" and (.actual | test("/\\.githooks")))' "$tmp/hp-tilde.json" >/dev/null ||
  fail "a declared hook under a tilde path was not recorded as an override with the expanded path: $(jq -c '[.findings[] | select(.id == "git-hook")]' "$tmp/hp-tilde.json")"

# Declared, but core.hooksPath is unset in this clone: the declaration says the
# repository's hooks are the guard and git is running the managed path instead.
# The managed hook is installed first, so the contradiction is the run's only
# failure and the non-compliant verdict is its doing alone.
git -C "$hp" config --unset core.hooksPath
"$CLI" repo diff "$hp" --json >"$tmp/hp-declared-noinstall.json" 2>/dev/null || true
jq -e '[.findings[] | select(.id == "git-hook" or .id == "git-policy-library") | .remediation] == ["", ""]' "$tmp/hp-declared-noinstall.json" >/dev/null ||
  fail "the managed rows offered the installer beside a repo-owned CONFLICT: $(jq -c '[.findings[] | select(.id == "git-hook" or .id == "git-policy-library")]' "$tmp/hp-declared-noinstall.json")"
"$SRC/bin/install-git-hooks.sh" "$hp" >/dev/null
"$CLI" repo diff "$hp" --json >"$tmp/hp-declared-unset.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "hooks-owner" and .status == "CONFLICT" and (.actual | test("core.hooksPath is unset")))' "$tmp/hp-declared-unset.json" >/dev/null ||
  fail "a repo-owned declaration with core.hooksPath unset was not reported: $(jq -c '[.findings[] | select(.id == "hooks-owner" or .id == "git-hook")]' "$tmp/hp-declared-unset.json")"
jq -e '[.findings[] | select(.status != "OK" and .status != "OVERRIDE") | .id] == ["hooks-owner"]' "$tmp/hp-declared-unset.json" >/dev/null ||
  fail "the contradicted declaration was not the only failure: $(jq -c '[.findings[] | select(.status != "OK")]' "$tmp/hp-declared-unset.json")"
jq -e '.compliant == false' "$tmp/hp-declared-unset.json" >/dev/null ||
  fail "a contradicted hooks declaration was reported compliant"

# An explicit managed with core.hooksPath unset is the ordinary managed state,
# and the documented default: compliant, with no hooks-owner row at all.
printf '%s\n' '{"schemaVersion":1,"profile":"personal","hooks":"managed"}' >"$hp/.llmctx.json"
"$CLI" repo diff "$hp" --json >"$tmp/hp-managed-unset.json" ||
  fail "an explicit managed declaration was not compliant: $(jq -c '[.findings[] | select(.status != "OK")]' "$tmp/hp-managed-unset.json")"
if jq -e 'any(.findings[]; .id == "hooks-owner")' "$tmp/hp-managed-unset.json" >/dev/null; then
  fail "an explicit managed declaration produced a hooks-owner finding"
fi

# core.hooksPath naming a file is "not a directory", never "does not exist".
git -C "$hp" config core.hooksPath .githooks/pre-commit
printf '%s\n' '{"schemaVersion":1,"profile":"personal","hooks":"repo-owned"}' >"$hp/.llmctx.json"
"$CLI" repo diff "$hp" --json >"$tmp/hp-file.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "policy-enforcement" and .status == "MISSING" and (.actual | test("is a file, not a directory")))' "$tmp/hp-file.json" >/dev/null ||
  fail "a core.hooksPath that is a file was not reported as such: $(jq -c '[.findings[] | select(.id == "policy-enforcement")]' "$tmp/hp-file.json")"
jq -e 'any(.findings[]; .id == "git-hook" and .status == "UNKNOWN" and (.actual | test("is a file, not a directory")))' "$tmp/hp-file.json" >/dev/null ||
  fail "git-hook called an existing file a missing directory: $(jq -c '[.findings[] | select(.id == "git-hook")]' "$tmp/hp-file.json")"
git -C "$hp" config --unset core.hooksPath

# A global core.hooksPath is not a framework the repository commits, however
# good its branch check: a fresh clone would have no hook at all. repo-owned over
# it is a CONFLICT naming the scope, and the rows stay UNKNOWN, never OVERRIDE.
mkdir -p "$tmp/ghooks"
printf '%s\n' '#!/bin/sh' 'git symbolic-ref --short HEAD' >"$tmp/ghooks/pre-commit"
git config --global core.hooksPath "$tmp/ghooks"
# Undeclared first: the pre-existing rows name the scope too, and their fix
# unsets the value where it is, not locally where it is not.
printf '%s\n' '{"schemaVersion":1,"profile":"personal"}' >"$hp/.llmctx.json"
"$CLI" repo diff "$hp" --json >"$tmp/hp-global-undeclared.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "git-hook" and .status == "UNKNOWN" and .source == "git-global") and any(.findings[]; .id == "policy-enforcement" and (.remediation | test("--global --unset")))' "$tmp/hp-global-undeclared.json" >/dev/null ||
  fail "an undeclared global core.hooksPath was attributed to local config: $(jq -c '[.findings[] | select(.id == "git-hook" or .id == "policy-enforcement")]' "$tmp/hp-global-undeclared.json")"
printf '%s\n' '{"schemaVersion":1,"profile":"personal","hooks":"repo-owned"}' >"$hp/.llmctx.json"
"$CLI" repo diff "$hp" --json >"$tmp/hp-global.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "hooks-owner" and .status == "CONFLICT" and (.actual | test("no tracked hook")) and (.actual | test("\\(global config\\)")))' "$tmp/hp-global.json" >/dev/null ||
  fail "repo-owned over a global core.hooksPath was honoured or misdescribed: $(jq -c '[.findings[] | select(.id == "hooks-owner" or .id == "git-hook")]' "$tmp/hp-global.json")"
if jq -e 'any(.findings[]; .status == "OVERRIDE" and (.id == "git-hook" or .id == "policy-enforcement"))' "$tmp/hp-global.json" >/dev/null; then
  fail "a global core.hooksPath satisfied a repo-owned declaration"
fi
jq -e '.compliant == false' "$tmp/hp-global.json" >/dev/null || fail "repo-owned over a global core.hooksPath was reported compliant"
printf '%s\n' '{"schemaVersion":1,"profile":"personal","hooks":"managed"}' >"$hp/.llmctx.json"
"$CLI" repo diff "$hp" --json >"$tmp/hp-global-managed.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "hooks-owner" and .status == "CONFLICT" and (.remediation | test("--global --unset")))' "$tmp/hp-global-managed.json" >/dev/null ||
  fail "the managed contradiction over a global core.hooksPath did not point at the global scope: $(jq -c '[.findings[] | select(.id == "hooks-owner")]' "$tmp/hp-global-managed.json")"
git config --global --unset core.hooksPath

# "Commits" is the repository's index, not the path: an untracked directory
# under the root fails it, and so does .git/hooks itself. A directory that
# cannot be entered lists nothing and is "not tracked", never an aborted run.
mkdir -p "$hp/.githooks-untracked"
printf '%s\n' '#!/bin/sh' 'git symbolic-ref --short HEAD' >"$hp/.githooks-untracked/pre-commit"
printf '%s\n' '{"schemaVersion":1,"profile":"personal","hooks":"repo-owned"}' >"$hp/.llmctx.json"
for hp_case in .githooks-untracked .git/hooks; do
  git -C "$hp" config core.hooksPath "$hp_case"
  "$CLI" repo diff "$hp" --json >"$tmp/hp-untracked.json" 2>/dev/null || true
  jq -e 'any(.findings[]; .id == "hooks-owner" and .status == "CONFLICT" and (.actual | test("no tracked hook")))' "$tmp/hp-untracked.json" >/dev/null ||
    fail "repo-owned over $hp_case was honoured: $(jq -c '[.findings[] | select(.id == "hooks-owner" or .id == "git-hook")]' "$tmp/hp-untracked.json")"
  if jq -e 'any(.findings[]; .status == "OVERRIDE")' "$tmp/hp-untracked.json" >/dev/null; then
    fail "repo-owned over $hp_case produced an override"
  fi
done
if [[ "$(id -u)" -ne 0 ]]; then
  chmod 000 "$hp/.githooks-untracked"
  git -C "$hp" config core.hooksPath .githooks-untracked
  "$CLI" repo diff "$hp" --json >"$tmp/hp-unreadable.json" 2>/dev/null || true
  chmod 755 "$hp/.githooks-untracked"
  jq -e '.findings | length > 3' "$tmp/hp-unreadable.json" >/dev/null ||
    fail "an unreadable hooks directory aborted the run: $(head -c 200 "$tmp/hp-unreadable.json")"
  jq -e 'any(.findings[]; .id == "git-hook" and .status == "UNKNOWN" and (.actual | test("cannot be read")))' "$tmp/hp-unreadable.json" >/dev/null ||
    fail "an unreadable hooks directory was not named as such: $(jq -c '[.findings[] | select(.id == "git-hook")]' "$tmp/hp-unreadable.json")"
  jq -e 'any(.findings[]; .id == "policy-enforcement" and .status == "MISSING" and (.actual | test("cannot be read")))' "$tmp/hp-unreadable.json" >/dev/null ||
    fail "an unreadable hooks directory was graded as if it had been read: $(jq -c '[.findings[] | select(.id == "policy-enforcement")]' "$tmp/hp-unreadable.json")"
fi

# The index is applied to the hook files, not to any file: a tracked README
# beside an untracked hook is no guard in a clone.
mkdir -p "$hp/.githooks-readme"
printf '%s\n' '# hooks' >"$hp/.githooks-readme/README.md"
printf '%s\n' '#!/bin/sh' 'git symbolic-ref --short HEAD' >"$hp/.githooks-readme/pre-commit"
git -C "$hp" add .githooks-readme/README.md
git -C "$hp" config core.hooksPath .githooks-readme
"$CLI" repo diff "$hp" --json >"$tmp/hp-readme.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "hooks-owner" and .status == "CONFLICT" and (.actual | test("no tracked hook")))' "$tmp/hp-readme.json" >/dev/null ||
  fail "a tracked README qualified an untracked hook: $(jq -c '[.findings[] | select(.id == "hooks-owner" or .id == "git-hook")]' "$tmp/hp-readme.json")"
if jq -e 'any(.findings[]; .status == "OVERRIDE")' "$tmp/hp-readme.json" >/dev/null; then
  fail "a tracked README beside an untracked hook produced an override"
fi
git -C "$hp" config --unset core.hooksPath

# A value injected with -c or GIT_CONFIG_PARAMETERS has scope "command", which
# no `git config --<scope>` flag names; the remediation says so in prose.
printf '%s\n' '{"schemaVersion":1,"profile":"personal","hooks":"managed"}' >"$hp/.llmctx.json"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=.githooks "$CLI" repo diff "$hp" --json >"$tmp/hp-command.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "hooks-owner" and .status == "CONFLICT" and (.actual | test("\\(command config\\)")) and (.remediation | test("--command") | not) and (.remediation | test("GIT_CONFIG_PARAMETERS")))' "$tmp/hp-command.json" >/dev/null ||
  fail "a command-scope core.hooksPath got a git flag that does not exist: $(jq -c '[.findings[] | select(.id == "hooks-owner")]' "$tmp/hp-command.json")"

# A tilde git cannot expand is not "unset": the directory is reported missing,
# which is what git itself says at commit time, and git-hook names the declared
# directory that is not there instead of a framework to integrate with. This
# case runs last: once the value is set, git refuses every later command in
# this repository, the --unset that would clear it included.
# shellcheck disable=SC2088 # the literal tilde is the case: git stores it and fails to expand it later
git -C "$hp" config core.hooksPath '~nosuchuser-llmctx/hk'
printf '%s\n' '{"schemaVersion":1,"profile":"personal","hooks":"repo-owned"}' >"$hp/.llmctx.json"
"$CLI" repo diff "$hp" --json >"$tmp/hp-badtilde.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "policy-enforcement" and .status == "MISSING" and (.actual | test("does not exist")))' "$tmp/hp-badtilde.json" >/dev/null ||
  fail "an unexpandable core.hooksPath was not reported as a missing directory: $(jq -c '[.findings[] | select(.status != "OK")]' "$tmp/hp-badtilde.json")"
if jq -e 'any(.findings[]; .id == "hooks-owner" and (.actual | test("unset")))' "$tmp/hp-badtilde.json" >/dev/null; then
  fail "an unexpandable core.hooksPath was read as unset"
fi
jq -e 'any(.findings[]; .id == "git-hook" and .status == "UNKNOWN" and (.actual | test("does not exist")))' "$tmp/hp-badtilde.json" >/dev/null ||
  fail "git-hook did not name the declared directory that is missing: $(jq -c '[.findings[] | select(.id == "git-hook")]' "$tmp/hp-badtilde.json")"

# --- a scaffold shim is MISSING, a foreign hook is UNKNOWN -------------------
#
# Both used to report one undifferentiated UNKNOWN. The shim is asking to be
# replaced by one command; the husky hook is an integration a person must look
# at. Reporting them identically is what kept the stalled handoff invisible.
shim="$tmp/shim"
mkdir -p "$shim"
git -C "$shim" init -q -b main
git -C "$shim" checkout -q -b feature/t
printf '%s\n' '{"schemaVersion":1,"profile":"personal","briefs":"tracker","claudeImport":false}' >"$shim/.llmctx.json"
printf '%s\n' '# Project instructions' >"$shim/AGENTS.md"
shim_hooks="$(git -C "$shim" rev-parse --git-path hooks)"
case "$shim_hooks" in /*) ;; *) shim_hooks="$shim/$shim_hooks" ;; esac
mkdir -p "$shim_hooks"
printf '%s\n' '#!/bin/sh' '# scaffold-hook-shim — placeholder' 'exec "$(dirname "$0")/pre-commit.local" "$@"' >"$shim_hooks/pre-commit"
"$CLI" repo diff "$shim" --json >"$tmp/shim.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "git-hook" and .status == "MISSING" and (.actual | test("scaffold")))' "$tmp/shim.json" >/dev/null ||
  fail "a scaffold shim was not reported as MISSING: $(jq -c '[.findings[] | select(.id == "git-hook")]' "$tmp/shim.json")"
printf '%s\n' '#!/bin/sh' '# husky' 'echo husky' >"$shim_hooks/pre-commit"
"$CLI" repo diff "$shim" --json >"$tmp/husky.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "git-hook" and .status == "UNKNOWN" and .actual == "foreign pre-commit hook")' "$tmp/husky.json" >/dev/null ||
  fail "a foreign hook was not reported as UNKNOWN: $(jq -c '[.findings[] | select(.id == "git-hook")]' "$tmp/husky.json")"

# sync-location. HOME is overridden rather than writing into the real home, and
# the repository is created under the fake HOME so the resolved path genuinely
# sits beneath a sync root. The OK case matters as much as the CONFLICT one: the
# iCloud Desktop & Documents arm keys off the CloudDocs mirror directory, so
# without that marker a repository in $HOME/Documents must NOT be flagged,
# otherwise every Mac reports a conflict it cannot act on.
synced_home="$tmp/fakehome"
mkdir -p "$synced_home/Dropbox/project"
git -C "$synced_home/Dropbox/project" init -q
if HOME="$synced_home" "$CLI" repo diff "$synced_home/Dropbox/project" --json >"$tmp/synced.json"; then
  fail "a repository inside Dropbox was reported compliant"
fi
jq -e 'any(.findings[]; .id == "sync-location" and .status == "CONFLICT")' "$tmp/synced.json" >/dev/null ||
  fail "a repository inside a sync root was not flagged"

mkdir -p "$synced_home/Documents/project"
git -C "$synced_home/Documents/project" init -q
HOME="$synced_home" "$CLI" repo diff "$synced_home/Documents/project" --json >"$tmp/docs-nosync.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "sync-location" and .status == "OK")' "$tmp/docs-nosync.json" >/dev/null ||
  fail "Documents was flagged without the iCloud Desktop & Documents marker"

mkdir -p "$synced_home/Library/Mobile Documents/com~apple~CloudDocs/Documents"
HOME="$synced_home" "$CLI" repo diff "$synced_home/Documents/project" --json >"$tmp/docs-sync.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "sync-location" and .status == "CONFLICT")' "$tmp/docs-sync.json" >/dev/null ||
  fail "Documents was not flagged once the iCloud mirror directory existed"

# An unreadable candidate must not take the command down. `cd` into it fails,
# and a failed command substitution under set -e aborted every finding, not just
# this one.
locked_home="$tmp/lockedhome"
mkdir -p "$locked_home/Dropbox" "$tmp/plain"
git -C "$tmp/plain" init -q
chmod 000 "$locked_home/Dropbox"
HOME="$locked_home" "$CLI" repo diff "$tmp/plain" --json >"$tmp/locked.json" 2>/dev/null || true
chmod 755 "$locked_home/Dropbox"
jq -e 'any(.findings[]; .id == "sync-location")' "$tmp/locked.json" >/dev/null ||
  fail "an unreadable sync-root candidate suppressed the whole report"

# A linked worktree keeps its refs in the shared Git directory, so a worktree
# outside a sync root whose shared .git is inside one is still at risk. Testing
# the checkout alone reported OK here, which is backwards.
wt_home="$tmp/wthome"
mkdir -p "$wt_home/Dropbox/upstream"
git -C "$wt_home/Dropbox/upstream" init -q
git -C "$wt_home/Dropbox/upstream" config user.email wt@example.test
git -C "$wt_home/Dropbox/upstream" config user.name "Worktree Test"
git -C "$wt_home/Dropbox/upstream" commit -q --allow-empty -m base
git -C "$wt_home/Dropbox/upstream" worktree add -q "$tmp/outside-wt" -b parked
HOME="$wt_home" "$CLI" repo diff "$tmp/outside-wt" --json >"$tmp/wt.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "sync-location" and .status == "CONFLICT" and (.actual | test("shared Git directory")))' "$tmp/wt.json" >/dev/null ||
  fail "a worktree whose shared Git directory is synced was not flagged"

# A second linked account renames the vendor folder, and matching only the bare
# path missed every such case.
variant_home="$tmp/varianthome"
for variant in "Dropbox (Personal)" "OneDrive - Example Org"; do
  mkdir -p "$variant_home/$variant/project"
  git -C "$variant_home/$variant/project" init -q
  HOME="$variant_home" "$CLI" repo diff "$variant_home/$variant/project" --json >"$tmp/variant.json" 2>/dev/null || true
  jq -e 'any(.findings[]; .id == "sync-location" and .status == "CONFLICT")' "$tmp/variant.json" >/dev/null ||
    fail "a repository under '$variant' was not flagged"
done

# A directory that merely STARTS with a vendor name is nobody's sync folder. A
# bare trailing glob flagged ~/Dropbox-notes as CONFLICT with "synced by
# Dropbox-notes", which fails `repo diff` for a repository whose location is
# fine — the false positive that teaches an owner to ignore this check.
prefix_home="$tmp/prefixhome"
for ordinary in "Dropbox-notes" "OneDriveBackup"; do
  mkdir -p "$prefix_home/$ordinary/project"
  git -C "$prefix_home/$ordinary/project" init -q
  HOME="$prefix_home" "$CLI" repo diff "$prefix_home/$ordinary/project" --json >"$tmp/prefix.json" 2>/dev/null || true
  jq -e 'any(.findings[]; .id == "sync-location" and .status == "OK")' "$tmp/prefix.json" >/dev/null ||
    fail "'$ordinary' is an ordinary directory and was flagged as a sync root"
done

# The vendor spellings a client really creates must still be caught, so the
# anchoring above cannot be mistaken for switching the check off.
mkdir -p "$prefix_home/Dropbox/project" "$prefix_home/Google Drive/project"
for real in "Dropbox" "Google Drive"; do
  git -C "$prefix_home/$real/project" init -q
  HOME="$prefix_home" "$CLI" repo diff "$prefix_home/$real/project" --json >"$tmp/realvendor.json" 2>/dev/null || true
  jq -e 'any(.findings[]; .id == "sync-location" and .status == "CONFLICT")' "$tmp/realvendor.json" >/dev/null ||
    fail "a repository under '$real' was not flagged"
done

# A literal pipe in the path must not truncate the reported path. The prefix
# list was moved to parallel arrays for this reason; the checked paths were
# still packed into one string and split on "|", so the finding named a
# directory that was not the one tested.
pipe_home="$tmp/pipehome"
mkdir -p "$pipe_home/Dropbox/weird|name/project"
git -C "$pipe_home/Dropbox/weird|name/project" init -q
HOME="$pipe_home" "$CLI" repo diff "$pipe_home/Dropbox/weird|name/project" --json >"$tmp/pipe.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "sync-location" and (.actual | contains("weird|name/project")))' "$tmp/pipe.json" >/dev/null ||
  fail "a path containing a pipe was truncated in the sync-location finding"

# Declarable, like claudeImport and briefs: moving the repository is the fix, and
# saying so out loud is the alternative.
optout_home="$tmp/optouthome"
mkdir -p "$optout_home/Dropbox/accepted"
git -C "$optout_home/Dropbox/accepted" init -q
printf '%s\n' '{"schemaVersion":1,"syncLocation":false}' >"$optout_home/Dropbox/accepted/.llmctx.json"
HOME="$optout_home" "$CLI" repo diff "$optout_home/Dropbox/accepted" --json >"$tmp/optout.json" 2>/dev/null || true
jq -e 'any(.findings[]; .id == "sync-location" and .status == "OVERRIDE")' "$tmp/optout.json" >/dev/null ||
  fail "the declared sync-location opt-out was not honoured"

echo "repo diff tests: passed"
