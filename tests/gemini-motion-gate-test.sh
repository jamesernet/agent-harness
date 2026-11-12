#!/usr/bin/env bash
set -euo pipefail

# The spend gate on the one skill in this repository that bills a third-party
# API per run. Nothing here touches the network: every case stops at or before
# the gate, and the key is removed from the environment so a case that got past
# the gate fails on a missing key instead of spending money.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
GEN="$SRC/skills/gemini-motion/scripts/generate_video.py"

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

echo "gemini-motion gate tests: passed"
