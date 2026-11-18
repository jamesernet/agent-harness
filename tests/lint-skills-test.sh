#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

# The lint reads the tree around its own location, so it runs against a fixture
# tree of the smallest shape it accepts: one owned skill, one vendored skill,
# and a bundles.conf that uses every member shape (a skill, a vendored skill,
# and a +bundle inclusion).
tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-lint-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fixture="$tmp/source"
mkdir -p "$fixture/bin" "$fixture/tests" "$fixture/skills/owned" "$fixture/vendor/vendored"
cp "$SRC/bin/lint-skills.sh" "$fixture/bin/"
printf '%s\n' '---' 'name: owned' 'description: An owned skill.' '---' '# Owned' >"$fixture/skills/owned/SKILL.md"
printf '%s\n' '# Vendored skill' >"$fixture/vendor/vendored/SKILL.md"
bundles="$fixture/skills/bundles.conf"
reset_bundles() {
  printf '%s\n' '# comment line' 'core|owned' '' 'website|+core' 'website|vendored' >"$bundles"
}

fail() {
  echo "lint-skills test failed: $*" >&2
  exit 1
}
# lint runs the fixture's copy and leaves its output in $out and its status in $rc.
lint() {
  rc=0
  out="$(bash "$fixture/bin/lint-skills.sh" 2>&1)" || rc=$?
}

# 1. The fixture passes: a skill, a vendored skill and a +bundle inclusion are
#    all members a bundle may name.
reset_bundles
lint
[ "$rc" -eq 0 ] || fail "the fixture tree did not pass lint: $out"
grep -q 'lint: all skills and agents OK' <<<"$out" || fail "lint passed without saying so: $out"

# 2. A bundle line naming a skill that ships nowhere fails, naming the bundle
#    and the member. This is the line a skill removal leaves behind; the
#    installer only warns about it, on the user's machine.
reset_bundles
printf '%s\n' 'metered|plan-to-video' >>"$bundles"
lint
[ "$rc" -ne 0 ] || fail "a bundle line naming a missing skill passed lint: $out"
grep -q 'bundle "metered" names "plan-to-video"' <<<"$out" ||
  fail "the missing skill was not reported by bundle and name: $out"

# 3. A +bundle that no line defines fails the same way. The installer expands
#    it to nothing without a word.
reset_bundles
printf '%s\n' 'webapp|+nope' >>"$bundles"
lint
[ "$rc" -ne 0 ] || fail "an inclusion of an undefined bundle passed lint: $out"
grep -q 'bundle "webapp" includes "+nope"' <<<"$out" ||
  fail "the undefined bundle was not reported by bundle and name: $out"

# 4. The other direction still holds: an owned skill in no bundle fails.
reset_bundles
printf '%s\n' '# comment line' 'website|vendored' >"$bundles"
lint
[ "$rc" -ne 0 ] || fail "an owned skill in no bundle passed lint: $out"
grep -q 'owned: in no bundle' <<<"$out" || fail "the unbundled skill was not reported: $out"

# 5. The message carries the line, so two identical stale lines are told apart.
#    The fixture is five lines, so an appended line is line 6.
reset_bundles
printf '%s\n' 'metered|plan-to-video' >>"$bundles"
lint
grep -q 'skills/bundles.conf:6: bundle "metered"' <<<"$out" ||
  fail "the stale line was not reported with its line number: $out"

# 6. The passing fixture's shapes are live, not skipped: the vendored member
#    fails once its SKILL.md is gone, and the +core inclusion fails once no
#    line defines core any more (owned stays bundled, under another name).
reset_bundles
rm "$fixture/vendor/vendored/SKILL.md"
lint
[ "$rc" -ne 0 ] || fail "a vendored member with no SKILL.md passed lint: $out"
grep -q 'bundle "website" names "vendored"' <<<"$out" || fail "the vendored member was not checked: $out"
printf '%s\n' '# Vendored skill' >"$fixture/vendor/vendored/SKILL.md"
printf '%s\n' '# comment line' 'kore|owned' 'website|+core' 'website|vendored' >"$bundles"
lint
[ "$rc" -ne 0 ] || fail "an inclusion of a bundle that was renamed away passed lint: $out"
grep -q 'bundle "website" includes "+core"' <<<"$out" || fail "the +core inclusion was not checked: $out"

# 7. A bundle name the installer cannot match -- indented, or empty -- fails,
#    because llmctx_bundle_expand compares the name exactly and skips the line.
reset_bundles
printf '%s\n' '  core|owned' '|owned' >>"$bundles"
lint
[ "$rc" -ne 0 ] || fail "a bundle name the installer never matches passed lint: $out"
grep -q 'bundle name "  core" is not \[a-z0-9-\]' <<<"$out" || fail "the indented bundle name was not reported: $out"
grep -q 'bundle name "" is not \[a-z0-9-\]' <<<"$out" || fail "the empty bundle name was not reported: $out"

# 8. The +bundle name is compared as a string, not a pattern: +web.site is
#    undefined although "web.site" would match "website" as a regex.
reset_bundles
printf '%s\n' 'webapp|+web.site' >>"$bundles"
lint
[ "$rc" -ne 0 ] || fail "+web.site passed lint by matching website as a pattern: $out"
grep -q 'bundle "webapp" includes "+web.site"' <<<"$out" || fail "the near-miss inclusion was not reported: $out"

# 9. all is computed by the installer, never read from this file: a line that
#    defines it is dead, and an inclusion of it expands to nothing.
reset_bundles
printf '%s\n' 'all|owned' 'webapp|+all' >>"$bundles"
lint
[ "$rc" -ne 0 ] || fail "defining or including all passed lint: $out"
grep -q 'bundle "all" is computed by install-skills.sh' <<<"$out" || fail "the all definition line was not reported: $out"
grep -q 'bundle "webapp" includes "+all", which is computed' <<<"$out" || fail "the +all inclusion was not reported: $out"

echo "lint-skills tests: passed"
