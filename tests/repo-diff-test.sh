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
