#!/usr/bin/env bash
set -euo pipefail

# The spend gate on plan-to-video. Nothing here touches the network: every case
# stops at or before the gate, and the key is removed from the environment so a
# case that got past the gate fails on a missing key instead of spending money.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
VIDEO="$SRC/skills/plan-to-video/scripts/video.py"

fail() {
  echo "plan-to-video gate test failed: $*" >&2
  exit 1
}

command -v python3 >/dev/null || {
  echo "plan-to-video gate tests: skipped (no python3)"
  exit 0
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-ptv-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
plan="$tmp/plan.json"

# Eight-second shots, because the plan validator requires them at 4k and this
# test moves the same plan between resolutions.
python3 - "$SRC" "$plan" <<'PY'
import json, sys
src, out = sys.argv[1], sys.argv[2]
p = json.load(open(f"{src}/skills/plan-to-video/references/example-plan.json"))
for s in p["shots"]:
    s["duration"] = 8
json.dump(p, open(out, "w"))
PY

set_resolution() {
  python3 - "$plan" "$1" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p["resolution"] = sys.argv[2]
json.dump(p, open(sys.argv[1], "w"))
PY
}

run() { env -u GEMINI_API_KEY -u GOOGLE_API_KEY python3 "$VIDEO" "$@" 2>&1 || true; }

# 1. check prices the pending shots and prints the token to approve with.
set_resolution 720p
out="$(run check "$plan")"
grep -q 'to render: 3 shots, 24s of video' <<<"$out" ||
  fail "check did not price the plan: $out"
grep -q -- '--approve 24s@720p' <<<"$out" ||
  fail "check did not print the approval token: $out"

# 2. Seconds alone are refused by name. They used to BE the approval, and the
#    plan's resolution could change under them.
out="$(run render "$plan" --approve 24)"
grep -q 'not seconds alone' <<<"$out" ||
  fail "an approval of seconds alone was not refused: $out"

# 3. The defect this gate was rewritten for: approve at 720p, edit the plan to
#    4k, render. Same seconds, several times the bill.
set_resolution 4k
out="$(run render "$plan" --approve 24s@720p)"
grep -q "this render is 24s@4k but --approve says" <<<"$out" ||
  fail "a plan edited to a higher resolution was rendered on the old approval: $out"

# 4. The matching token gets past the gate -- proven by the next failure being
#    the missing key, which is as far as this test goes.
out="$(run render "$plan" --approve 24s@4k)"
grep -q 'GEMINI_API_KEY is not set' <<<"$out" ||
  fail "the matching token did not get past the gate: $out"

echo "plan-to-video gate tests: passed"
