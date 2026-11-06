#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-doctor-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd)"
copy="$tmp/source"
test_home="$tmp/home"
mkdir -p "$copy" "$test_home"
tar -C "$SRC" --exclude=.git -cf - . | tar -C "$copy" -xf -
rm -rf "$copy/skills" "$copy/vendor"
mkdir -p "$copy/skills/codebase-design" "$copy/vendor/example-vendor"
printf '%s\n' '# Codebase design' >"$copy/skills/codebase-design/SKILL.md"
printf '%s\n' '# Example vendor' >"$copy/vendor/example-vendor/SKILL.md"
git -C "$copy" init -q
export GIT_CONFIG_GLOBAL="$tmp/global.gitconfig"

# Private machine settings may be installed before agent-harness. Installation
# must preserve keys this public repository does not own.
mkdir -p "$test_home/.claude"
printf '%s\n' '{"permissions":{"allow":["Private(example)"]},"theme":"dark"}' \
  >"$test_home/.claude/settings.json"

fail() {
  echo "doctor test failed: $*" >&2
  exit 1
}

if HOME="$test_home" "$copy/bin/llmctx" doctor --json >"$tmp/missing.json"; then
  fail "unconfigured machine was reported healthy"
fi
jq -e '.healthy == false and any(.checks[]; .id == "adapters" and .status == "FAIL")' "$tmp/missing.json" >/dev/null ||
  fail "missing adapters were not reported"

HOME="$test_home" "$copy/install.sh" >/dev/null
jq -e '.permissions.allow == ["Private(example)"] and .theme == "dark" and (.hooks.PreToolUse | length) == 2' \
  "$test_home/.claude/settings.json" >/dev/null || fail "private Claude settings were not preserved"
HOME="$test_home" "$copy/bin/llmctx" doctor --json >"$tmp/healthy.json" ||
  fail "installed machine was reported unhealthy"
jq -e '.healthy == true and all(.checks[]; .status == "PASS")' "$tmp/healthy.json" >/dev/null ||
  fail "healthy JSON contained a failure"
HOME="$test_home" "$copy/bin/llmctx" doctor --quiet || fail "quiet check failed"
[[ -z "$(HOME="$test_home" "$copy/bin/llmctx" doctor --quiet)" ]] || fail "quiet check produced output"

# An unresolved @import is SILENT in a session: the rules simply do not load.
# The installed file is byte-identical to a correct render, because render_claude
# names these paths without ever reading them.
#
# adapters FAILs here too, now that --check runs the same scan -- it did not
# before, and that gap under --account is what justified this check. What
# adapters still cannot do is say WHICH path died: its detail is "missing or
# stale" and its remedy is install.sh. So the assertion is on the filename, not
# on being the only witness.
mv "$copy/global/handoff-and-briefs.md" "$tmp/handoff-and-briefs.md"
if HOME="$test_home" "$copy/bin/llmctx" doctor --json --account default >"$tmp/imports.json"; then
  fail "an unresolvable @import target was reported healthy"
fi
jq -e 'any(.checks[]; .id == "claude-imports" and .status == "FAIL" and (.detail | contains("handoff-and-briefs.md")))' \
  "$tmp/imports.json" >/dev/null || fail "the dead @import target was not named"
jq -e 'any(.checks[]; .id == "adapters" and (.detail | contains("handoff-and-briefs.md"))) | not' \
  "$tmp/imports.json" >/dev/null || fail "adapters named the dead path, so this check adds nothing"
mv "$tmp/handoff-and-briefs.md" "$copy/global/handoff-and-briefs.md"

# The hand-edited row of the table in #30. Any hand edit is also adapter drift,
# so assert on this check's id alone, never on all(.checks[]; ...).
printf '@%s\n' "$copy/global/typo-does-not-exist.md" >>"$test_home/.claude/CLAUDE.md"
if HOME="$test_home" "$copy/bin/llmctx" doctor --json >"$tmp/imports-typo.json"; then
  fail "a hand-edited dead @import line was reported healthy"
fi
jq -e 'any(.checks[]; .id == "claude-imports" and .status == "FAIL")' \
  "$tmp/imports-typo.json" >/dev/null || fail "a typo'd @ line was not reported"
HOME="$test_home" "$copy/install.sh" >/dev/null

# Claude Code does not expand shell variables, so this form is reported as a
# visible skip rather than asserted broken -- the only way decision (c) in #30
# is observable.
# Appending the line is adapter drift too, so doctor exits non-zero either way;
# the claim under test is this check's verdict, not the overall exit.
printf '@$HOME/nope.md\n' >>"$test_home/.claude/CLAUDE.md"
HOME="$test_home" "$copy/bin/llmctx" doctor --json >"$tmp/imports-unsupported.json" || true
jq -e 'any(.checks[]; .id == "claude-imports" and .status == "PASS" and (.detail | contains("skipped")))' \
  "$tmp/imports-unsupported.json" >/dev/null || fail "the unsupported path form was not reported as a skip"
HOME="$test_home" "$copy/install.sh" >/dev/null

# A checkout path containing a space used to make EVERY import "unsupported",
# so the check reported PASS having verified nothing and #30's own headline
# scenario stayed invisible. Nothing else in tests/ uses a space-bearing path,
# and CI installs under mktemp -d, so this was invisible to the whole suite.
spaced="$tmp/My Source Dir"
mkdir -p "$spaced"
tar -C "$copy" -cf - . | tar -C "$spaced" -xf -
git -C "$spaced" init -q .
spaced_home="$tmp/home-spaced"
mkdir -p "$spaced_home"
HOME="$spaced_home" "$spaced/install.sh" >/dev/null
HOME="$spaced_home" "$spaced/bin/llmctx" doctor --json >"$tmp/spaced-ok.json" ||
  fail "a space-bearing checkout was reported unhealthy"
jq -e 'any(.checks[]; .id == "claude-imports" and .status == "PASS" and (.detail | startswith("3 direct")))' \
  "$tmp/spaced-ok.json" >/dev/null ||
  fail "imports under a space-bearing path were not actually checked"

mv "$spaced/global/handoff-and-briefs.md" "$tmp/spaced-stash.md"
if HOME="$spaced_home" "$spaced/bin/llmctx" doctor --json --account default >"$tmp/spaced-dead.json"; then
  fail "a dead @import under a space-bearing path was reported healthy"
fi
jq -e 'any(.checks[]; .id == "claude-imports" and .status == "FAIL" and (.detail | contains("handoff-and-briefs.md")))' \
  "$tmp/spaced-dead.json" >/dev/null ||
  fail "the dead target under a space-bearing path was not named"
mv "$tmp/spaced-stash.md" "$spaced/global/handoff-and-briefs.md"

# "direct" is the one-level limit disclosing itself on the line a reader trusts.
# Pinning the word stops the wording quietly becoming a claim of completeness.
HOME="$test_home" "$copy/bin/llmctx" doctor --json >"$tmp/imports-ok.json" ||
  fail "a correct install was reported unhealthy by the import check"
jq -e 'any(.checks[]; .id == "claude-imports" and .status == "PASS" and (.detail | contains("direct")))' \
  "$tmp/imports-ok.json" >/dev/null || fail "resolving imports were not reported as direct-only"

HOME="$test_home" "$copy/bin/llmctx" skills install --dev >/dev/null
HOME="$test_home" "$copy/bin/llmctx" doctor --json >"$tmp/development.json" ||
  fail "development skill install was reported unhealthy"
jq -e 'all(.checks[] | select(.id == "claude-skills" or .id == "codex-skills"); .detail | contains("development links"))' \
  "$tmp/development.json" >/dev/null || fail "development mode was not identified"
HOME="$test_home" "$copy/bin/llmctx" skills install >/dev/null

rm -rf "$test_home/.claude/skills/codebase-design"
ln -s "$copy/skills/codebase-design" "$test_home/.claude/skills/codebase-design"
if HOME="$test_home" "$copy/bin/llmctx" doctor --json >"$tmp/mixed.json"; then
  fail "mixed skill modes were reported healthy"
fi
jq -e 'any(.checks[]; .id == "claude-skills" and (.detail | contains("mix copy and development")))' \
  "$tmp/mixed.json" >/dev/null || fail "mixed skill modes were not identified"
HOME="$test_home" "$copy/bin/llmctx" skills install >/dev/null

printf '\nlocal skill drift\n' >>"$test_home/.claude/skills/codebase-design/SKILL.md"
if HOME="$test_home" "$copy/bin/llmctx" doctor --json >"$tmp/skill-drift.json"; then
  fail "skill drift was reported healthy"
fi
jq -e 'any(.checks[]; .id == "claude-skills" and .status == "FAIL")' "$tmp/skill-drift.json" >/dev/null ||
  fail "skill drift was not identified"
HOME="$test_home" "$copy/bin/llmctx" skills install >/dev/null

printf '\nlocal drift\n' >>"$test_home/.codex/AGENTS.md"
if HOME="$test_home" "$copy/bin/llmctx" doctor --quiet; then
  fail "adapter drift was reported healthy"
fi

if HOME="$test_home" "$copy/bin/llmctx" doctor --json --quiet >/dev/null 2>&1; then
  fail "conflicting output modes were accepted"
fi

# A narrowed bundle must not read as a broken install. Counting the whole
# catalogue made doctor list every deliberately absent skill as needing
# attention while skill-bundle passed alongside it saying the opposite.
nb_home="$tmp/narrowed-home"
mkdir -p "$nb_home"
git config --global llmctx.skillBundle core
HOME="$nb_home" "$SRC/bin/install-skills.sh" >/dev/null 2>&1 ||
  fail "narrowed install failed"
HOME="$nb_home" "$SRC/bin/doctor.sh" --json >"$tmp/narrowed.json" 2>/dev/null || true
jq -e '.checks[] | select(.id == "claude-skills") | select(.status == "PASS")' \
  "$tmp/narrowed.json" >/dev/null ||
  fail "a narrowed bundle reported the skill set as broken"

# An account with its own bundle is judged against that bundle, not the global.
git config --global --add llmctx.claudeAccount "acme=$nb_home/.claude-acme"
git config --global llmctx.skillBundle.acme fintech
HOME="$nb_home" "$SRC/bin/install-skills.sh" >/dev/null 2>&1 ||
  fail "per-account install failed"
HOME="$nb_home" "$SRC/bin/doctor.sh" --json >"$tmp/per-account.json" 2>/dev/null || true
jq -e '.checks[] | select(.id == "claude-skills[acme]") | select(.status == "PASS")' \
  "$tmp/per-account.json" >/dev/null ||
  fail "an account bundle was judged against the global bundle"
jq -e '.checks[] | select(.id == "skill-bundle") | .detail | contains("acme")' \
  "$tmp/per-account.json" >/dev/null ||
  fail "skill-bundle did not report the per-account override"

git config --global --unset llmctx.skillBundle.acme
git config --global --unset llmctx.skillBundle
git config --global --unset-all llmctx.claudeAccount

echo "doctor tests: passed"
