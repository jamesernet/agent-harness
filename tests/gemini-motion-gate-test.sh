#!/usr/bin/env bash
set -euo pipefail

# The spend gate on the one skill in this repository that bills a third-party
# API per run, at both of its entry points: generate_video.py renders one clip,
# storyboard.py renders a plan of them. Nothing here touches the network: every
# case stops at or before the gate, and the key is removed from the environment
# so a case that got past the gate fails on a missing key instead of spending
# money.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
GEN="$SRC/skills/gemini-motion/scripts/generate_video.py"
SB="$SRC/skills/gemini-motion/scripts/storyboard.py"
EXAMPLE="$SRC/skills/gemini-motion/references/storyboard-example.json"

fail() {
  echo "gemini-motion gate test failed: $*" >&2
  exit 1
}

command -v python3 >/dev/null || {
  echo "gemini-motion gate tests: skipped (no python3)"
  exit 0
}

# Both spellings of the key, because the script accepts either.
gate() {
  env -u GEMINI_API_KEY -u GOOGLE_API_KEY python3 "$GEN" "$@" 2>&1 || true
}

# 1. No approval: the gate prices the render, prints the token to approve with,
#    and renders nothing.
out="$(gate "a cat" --duration 6 --draft)"
grep -q 'bills 6s at 360p, about \$0.18' <<<"$out" ||
  fail "the unapproved run did not price the render: $out"
grep -q 'approve with: --approve 6s@360p' <<<"$out" ||
  fail "the unapproved run did not print the approval token: $out"

# 2. The approval has to carry the resolution. Seconds alone priced one render
#    and licensed another: at 6s, 360p bills $0.18 and 4k bills $1.80, and
#    --approve 6 satisfied both.
out="$(gate "a cat" --duration 6 --resolution 4k --approve 6)"
grep -q 'not seconds alone' <<<"$out" ||
  fail "an approval of seconds alone was not refused: $out"

# 3. The token approved must be the token priced. This is the case the old gate
#    passed: approve the cheap draft, render at 4k, bill ten times.
out="$(gate "a cat" --duration 6 --resolution 4k --approve 6s@360p)"
grep -q 'bills 6s@4k but --approve says' <<<"$out" ||
  fail "an approval for a cheaper resolution was accepted: $out"

# 4. Changing the LENGTH after the approval is refused the same way.
out="$(gate "a cat" --duration 10 --draft --approve 6s@360p)"
grep -q 'bills 10s@360p but --approve says' <<<"$out" ||
  fail "an approval for a shorter clip was accepted: $out"

# 5. The matching token gets past the gate -- proven by the next failure being
#    the missing key rather than the gate, which is as far as this test goes.
out="$(gate "a cat" --duration 6 --draft --approve 6s@360p)"
grep -qE 'GEMINI_API_KEY is not set|google-genai package is not installed' <<<"$out" ||
  fail "the matching token did not get past the gate: $out"

# 6. With no --duration the model chooses the length, so the price quoted is the
#    worst case rather than a guess.
out="$(gate "a cat" --draft)"
grep -q 'bills 10s at 360p' <<<"$out" ||
  fail "an unpinned length was not priced at the worst case: $out"

# 7. An extend returns the whole clip, and the rate is per second of OUTPUT, so
#    the price of a continuation is not the increment. Pricing it from the
#    10-second single-clip ceiling understated a 40-second result by 4x.
out="$(gate "extend this" --previous-id v1_abc)"
grep -q 'bills 40s at 720p, about \$4.00' <<<"$out" ||
  fail "an extend was not priced by the whole output: $out"
grep -q 'the rate applies to the WHOLE' <<<"$out" ||
  fail "an extend did not say what it is pricing: $out"

# 8. --output-seconds pins the finished length, so a user who knows it approves
#    less than the ceiling.
out="$(gate "extend this" --previous-id v1_abc --output-seconds 24)"
grep -q 'bills 24s at 720p, about \$2.40' <<<"$out" ||
  fail "--output-seconds did not pin the price: $out"

# 9. --task extend takes the same path with no --previous-id.
out="$(gate "extend this" --task extend)"
grep -q 'bills 40s at 720p' <<<"$out" ||
  fail "--task extend was priced as a fresh clip: $out"

# 10. Two flags that set the resolution to different values are refused rather
#     than silently ranked: --draft won, and the user was told nothing.
out="$(gate "a cat" --draft --resolution 4k --duration 6)"
grep -q 'pass one of them' <<<"$out" ||
  fail "--draft silently overrode an explicit --resolution: $out"

# --- storyboard.py: the same gate over a plan of shots -----------------------
#
# The plan lives in a temp directory because the cases below edit it between
# check and render, which is the defect the token exists to catch.

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-storyboard-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
plan="$tmp/plan.json"
cp "$EXAMPLE" "$plan"

# set_plan KEY VALUE edits a top-level field; set_shot N KEY VALUE edits shot N
# (1-based). VALUE is JSON, so a string needs its own quotes.
set_plan() {
  python3 - "$plan" "$1" "$2" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p[sys.argv[2]] = json.loads(sys.argv[3])
json.dump(p, open(sys.argv[1], "w"))
PY
}
set_shot() {
  python3 - "$plan" "$1" "$2" "$3" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
p["shots"][int(sys.argv[2]) - 1][sys.argv[3]] = json.loads(sys.argv[4])
json.dump(p, open(sys.argv[1], "w"))
PY
}

sb() {
  env -u GEMINI_API_KEY -u GOOGLE_API_KEY python3 "$SB" "$@" 2>&1 || true
}

# 11. No approval: check prices every pending shot, the total, the dollar
#     estimate and the token to approve with, renders nothing, and exits 0.
#     The example plan is 8 + 4 + 6 seconds at 720p.
out="$(env -u GEMINI_API_KEY -u GOOGLE_API_KEY python3 "$SB" check "$plan" 2>&1)" ||
  fail "check on a valid plan did not exit 0: $out"
grep -qE '01 +desk +8s' <<<"$out" ||
  fail "check did not print a per-shot line: $out"
grep -q 'to render: 3 shots, 18s at 720p, about \$1.80' <<<"$out" ||
  fail "check did not price the plan: $out"
grep -q -- 'approve with: .*--approve 18s@720p' <<<"$out" ||
  fail "check did not print the approval token: $out"
[ ! -e "$tmp/out" ] ||
  fail "check wrote an out/ directory; pricing must not leave files behind"

# 12. Seconds alone are refused by name. They used to BE the approval, and the
#     plan's resolution could change under them.
out="$(sb render "$plan" --approve 18)"
grep -q 'not seconds alone' <<<"$out" ||
  fail "an approval of seconds alone was not refused: $out"
grep -q '18s@720p' <<<"$out" ||
  fail "the refusal did not name the token to use instead: $out"

# 13. The defect this gate exists for: approve at 720p, edit the plan to 4k,
#     render. Same seconds, three times the bill. The token is recomputed from
#     the plan on disk, so the old one no longer matches.
set_plan resolution '"4k"'
out="$(sb render "$plan" --approve 18s@720p)"
grep -q 'bills 18s@4k but --approve says' <<<"$out" ||
  fail "a plan edited to a higher resolution was rendered on the old approval: $out"

# 14. The matching token gets past the gate -- proven by the next failure being
#     the missing key, which is as far as this test goes. By then out/ exists
#     and already ignores itself: the protection arrives with the directory.
out="$(sb render "$plan" --approve 18s@4k)"
grep -qE 'GEMINI_API_KEY is not set|google-genai package is not installed' <<<"$out" ||
  fail "the matching token did not get past the gate: $out"
[ "$(cat "$tmp/out/.gitignore" 2>/dev/null | tail -1)" = "*" ] ||
  fail "out/ was created without a .gitignore that ignores it"

# 15. Omni's limits are checked before anything is priced, each refusal naming
#     the limit: a shot longer than one call renders, a resolution the rate
#     table does not price, and an image the model would reject -- an empty
#     file (what a failed download leaves) and an SVG -- through the same
#     image_block the render uses, so the plan fails here and not at the API.
cp "$EXAMPLE" "$plan"
set_shot 2 duration 12
out="$(sb check "$plan")"
grep -q 'shot 2 (coffee): duration must be a whole number of seconds from 3 to 10' <<<"$out" ||
  fail "a 12-second shot was not refused by name: $out"

cp "$EXAMPLE" "$plan"
set_plan resolution '"480p"'
out="$(sb check "$plan")"
grep -q "resolution '480p' is not one of 360p, 720p, 1080p, 4k" <<<"$out" ||
  fail "an unpriced resolution was not refused by name: $out"

cp "$EXAMPLE" "$plan"
: >"$tmp/empty.png"
set_shot 1 first_frame '"empty.png"'
out="$(sb check "$plan")"
grep -q 'image file is empty' <<<"$out" ||
  fail "an empty image file was not refused before pricing: $out"

cp "$EXAMPLE" "$plan"
echo '<svg xmlns="http://www.w3.org/2000/svg"/>' >"$tmp/logo.svg"
set_shot 1 images '["logo.svg"]'
out="$(sb check "$plan")"
grep -q 'does not accept image/svg+xml' <<<"$out" ||
  fail "an SVG reference was not refused before pricing: $out"

echo "gemini-motion gate tests: passed"
