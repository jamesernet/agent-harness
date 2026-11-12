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
# The hook-entry count is read from what this repository DECLARES rather than
# written as a literal. The invariant being pinned is "installation added the
# entries claude/settings.json declares and no others" — a hardcoded number
# says nothing about that, and breaks on every hook added thereafter, which is
# a test failure that teaches nothing.
declared_hooks="$(jq '.hooks.PreToolUse | length' "$copy/claude/settings.json")"
jq -e --argjson n "$declared_hooks" \
  '.permissions.allow == ["Private(example)"] and .theme == "dark" and (.hooks.PreToolUse | length) == $n' \
  "$test_home/.claude/settings.json" >/dev/null || fail "private Claude settings were not preserved"
HOME="$test_home" "$copy/bin/llmctx" doctor --json >"$tmp/healthy.json" ||
  fail "installed machine was reported unhealthy"
jq -e '.healthy == true and all(.checks[]; .status == "PASS")' "$tmp/healthy.json" >/dev/null ||
  fail "healthy JSON contained a failure"
HOME="$test_home" "$copy/bin/llmctx" doctor --quiet || fail "quiet check failed"
[[ -z "$(HOME="$test_home" "$copy/bin/llmctx" doctor --quiet)" ]] || fail "quiet check produced output"

# --- an unmanaged hook in an account's hooks directory (#52) -----------------
#
# The directory is installed into and never pruned, on purpose, so a hook
# written by hand survives a reinstall. Nothing used to SAY one was there:
# this machine carried two predecessors for months, one of them still
# registered and running beside its managed successor, while doctor reported
# healthy. It reports and never prunes, and a deliberate script is declared.
hooks_dir="$test_home/.claude/hooks"
printf '%s\n' '#!/bin/sh' 'exit 0' >"$hooks_dir/left-over-guard.sh"
chmod +x "$hooks_dir/left-over-guard.sh"
HOME="$test_home" "$copy/bin/llmctx" doctor --json >"$tmp/hook-unreg.json" 2>/dev/null || true
jq -e '.healthy == false and any(.checks[]; .id == "claude-hooks" and .status == "FAIL"
  and (.detail | contains("left-over-guard.sh")) and (.detail | contains("registered nowhere")))' \
  "$tmp/hook-unreg.json" >/dev/null ||
  fail "an unmanaged hook was not reported: $(jq -c '[.checks[] | select(.id == "claude-hooks")]' "$tmp/hook-unreg.json")"
[[ -f "$hooks_dir/left-over-guard.sh" ]] || fail "doctor deleted an unmanaged hook; it must only report"

# Still registered in settings is a second enforcer, not clutter, and is said
# differently -- that is the state that ran on every Edit, Write and Bash call.
settings_tmp="$tmp/settings-with-leftover.json"
jq '.hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":"$HOME/.claude/hooks/left-over-guard.sh"}]}]' \
  "$test_home/.claude/settings.json" >"$settings_tmp"
cp "$settings_tmp" "$test_home/.claude/settings.json"
HOME="$test_home" "$copy/bin/llmctx" doctor --json >"$tmp/hook-reg.json" 2>/dev/null || true
jq -e 'any(.checks[]; .id == "claude-hooks" and .status == "FAIL"
  and (.detail | contains("STILL REGISTERED")) and (.detail | contains("left-over-guard.sh")))' \
  "$tmp/hook-reg.json" >/dev/null ||
  fail "a registered unmanaged hook was not distinguished: $(jq -c '[.checks[] | select(.id == "claude-hooks")]' "$tmp/hook-reg.json")"

# Declared deliberate: the same idiom as llmctx.repo, so this does not become
# a check a mature machine must learn to ignore.
git config --global --add llmctx.accountHook left-over-guard.sh
HOME="$test_home" "$copy/bin/llmctx" doctor --json >"$tmp/hook-ok.json" 2>/dev/null || true
jq -e 'any(.checks[]; .id == "claude-hooks" and .status == "PASS")' "$tmp/hook-ok.json" >/dev/null ||
  fail "a declared hook was still reported: $(jq -c '[.checks[] | select(.id == "claude-hooks")]' "$tmp/hook-ok.json")"
git config --global --unset-all llmctx.accountHook
rm -f "$hooks_dir/left-over-guard.sh"
# The settings entry goes too. Left behind it is a registration with no file,
# which the check reports in its own right -- correctly, and it would mask
# every assertion after this one.
jq 'del(.hooks.PreToolUse[] | select(.hooks[].command | test("left-over-guard")))' \
  "$test_home/.claude/settings.json" >"$tmp/s0.json"
cp "$tmp/s0.json" "$test_home/.claude/settings.json"
HOME="$test_home" "$copy/bin/llmctx" doctor --json >"$tmp/hook-gone.json" 2>/dev/null || true
jq -e 'any(.checks[]; .id == "claude-hooks" and .status == "PASS")' "$tmp/hook-gone.json" >/dev/null ||
  fail "removing both the script and its entry did not clear the check: $(jq -c '[.checks[] | select(.id == "claude-hooks")]' "$tmp/hook-gone.json")"

# --- what the review of this change found ---------------------------------
#
# A registered hook with NO .sh extension was invisible: the walk globbed
# *.sh, which is what both of the predecessors that motivated this happened
# to be called, so the check passed on the exact state it exists to catch.
# The walk now takes every file, and the settings are read from the other
# side too, so a registration into this directory is caught whatever its
# name.
hook_settings() { # <jq filter> -- rewrite the account's settings.json
  jq "$1" "$test_home/.claude/settings.json" >"$tmp/s.json"
  cp "$tmp/s.json" "$test_home/.claude/settings.json"
}
hook_check() { # -> the claude-hooks check as compact JSON
  HOME="$test_home" "$copy/bin/llmctx" doctor --json >"$tmp/h.json" 2>/dev/null || true
  jq -c '[.checks[] | select(.id == "claude-hooks")][0]' "$tmp/h.json"
}
printf '%s\n' '#!/bin/sh' 'exit 0' >"$hooks_dir/no-extension"
chmod +x "$hooks_dir/no-extension"
hook_settings '.hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":"$HOME/.claude/hooks/no-extension"}]}]'
r="$(hook_check)"
[[ "$(jq -r .status <<<"$r")" == FAIL && "$(jq -r .detail <<<"$r")" == *"STILL REGISTERED"*"no-extension"* ]] ||
  fail "a registered hook with no .sh extension was not reported: $r"
hook_settings 'del(.hooks.PreToolUse[] | select(.hooks[].command | test("no-extension")))'
# ...and the same file with no registration at all, which only the directory
# walk can see. Without this the widened glob is not pinned: the registered
# case above is caught from the settings side whatever the walk globs.
r="$(hook_check)"
[[ "$(jq -r .detail <<<"$r")" == *"registered nowhere"*"no-extension"* ]] ||
  fail "an unregistered hook with no .sh extension was not reported: $r"
rm -f "$hooks_dir/no-extension"
r="$(hook_check)"
[[ "$(jq -r .status <<<"$r")" == PASS ]] || fail "removing it did not clear the check: $r"

# A command may be an ARRAY. The old filter's split() errored on one, silently,
# so a hook that WAS registered read as "registered nowhere" -- the lesser
# remediation for the more dangerous state.
printf '%s\n' '#!/bin/sh' 'exit 0' >"$hooks_dir/array-form.sh"
hook_settings '.hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":["$HOME/.claude/hooks/array-form.sh","--flag"]}]}]'
r="$(hook_check)"
[[ "$(jq -r .detail <<<"$r")" == *"STILL REGISTERED"*"array-form.sh"* ]] ||
  fail "an array-form command did not count as a registration: $r"
hook_settings 'del(.hooks.PreToolUse[] | select(.hooks[].command | if type == "array" then any(test("array-form")) else test("array-form") end))'
rm -f "$hooks_dir/array-form.sh"

# The reference test is by PATH, not basename. A settings entry naming a
# same-named script in another directory does not make this one a second
# enforcer, and saying it does gives the wrong remediation.
printf '%s\n' '#!/bin/sh' 'exit 0' >"$hooks_dir/samename.sh"
hook_settings '.hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":"/elsewhere/entirely/samename.sh"}]}]'
r="$(hook_check)"
[[ "$(jq -r .detail <<<"$r")" == *"registered nowhere"*"samename.sh"* ]] ||
  fail "a same-named script elsewhere was conflated with this one: $r"
hook_settings 'del(.hooks.PreToolUse[] | select(.hooks[].command | if type == "array" then any(test("samename")) else test("samename") end))'
rm -f "$hooks_dir/samename.sh"

# A registration into this directory whose FILE IS GONE is a hook that fails
# every call it was meant to guard, and the directory walk cannot see it.
hook_settings '.hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":"$HOME/.claude/hooks/vanished.sh"}]}]'
r="$(hook_check)"
[[ "$(jq -r .detail <<<"$r")" == *"registered but MISSING"*"vanished.sh"* ]] ||
  fail "a registration with no file was not reported: $r"
hook_settings 'del(.hooks.PreToolUse[] | select(.hooks[].command | if type == "array" then any(test("vanished")) else test("vanished") end))'

# A directory that happens to end in .sh is not a script.
mkdir -p "$hooks_dir/notascript.sh"
r="$(hook_check)"
[[ "$(jq -r .detail <<<"$r")" != *notascript* ]] || fail "a directory was reported as a hook: $r"
rmdir "$hooks_dir/notascript.sh"

# The opt-out is declarable PER ACCOUNT as well as globally: each account's
# hooks/ is its own, and a global-only list would couple them.
printf '%s\n' '#!/bin/sh' 'exit 0' >"$hooks_dir/mine.sh"
git config --global --add llmctx.accountHook.default mine.sh
r="$(hook_check)"
[[ "$(jq -r .status <<<"$r")" == PASS ]] || fail "a per-account declaration was ignored: $r"
git config --global --unset-all llmctx.accountHook.default
r="$(hook_check)"
[[ "$(jq -r .status <<<"$r")" == FAIL ]] || fail "removing the declaration did not restore the report: $r"
rm -f "$hooks_dir/mine.sh"

# The managed libraries are managed, not unmanaged: llmctx-<name>.sh is ours
# when bin/lib/<name>.sh exists, derived rather than listed so it cannot drift.
[[ -f "$hooks_dir/llmctx-policy.sh" ]] || fail "test setup: the policy library was not installed"
HOME="$test_home" "$copy/bin/llmctx" doctor --json >"$tmp/hook-clean.json" 2>/dev/null || true
jq -e 'any(.checks[]; .id == "claude-hooks" and .status == "PASS" and .detail == "no unmanaged hooks")' \
  "$tmp/hook-clean.json" >/dev/null ||
  fail "a clean hooks directory did not pass: $(jq -c '[.checks[] | select(.id == "claude-hooks")]' "$tmp/hook-clean.json")"

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
