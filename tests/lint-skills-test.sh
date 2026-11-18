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

echo "lint-skills tests: passed"
