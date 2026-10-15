#!/usr/bin/env bash
set -euo pipefail

# The marker is rewritten, not preserved.
#
# sync_block used to reprint whatever llmctx:begin line the destination already
# had, so the marker was write-once: the only path that ever wrote it was the
# one that created the file. A repository rename could therefore never reach an
# existing mirror, and check-lib-sync.sh compares block CONTENT only, so the
# stale marker would never fail anything either. It would just rot.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../bin/sync-published-context.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "sync-published tests: FAILED — $1" >&2
  exit 1
}

src="$tmp/source.md"
printf 'new body line one\nnew body line two\n' >"$src"

# 1. A destination carrying a STALE marker gets the current one.
dest="$tmp/stale.md"
cat >"$dest" <<'EOF'
---
title: keep me
---
<!-- llmctx:begin — synced from llm-context/brand/voice-and-style.md; edit there, then run bin/build-adapters.sh. Do not edit between these markers. -->
old body
<!-- llmctx:end -->
trailing line
EOF

sync_block "brand/voice-and-style.md" "$src" "$dest"

grep -q 'synced from agent-harness/brand/voice-and-style.md' "$dest" ||
  fail "stale marker was preserved instead of rewritten"
grep -q 'llm-context' "$dest" &&
  fail "old repository name survived the sync"
grep -q 'title: keep me' "$dest" || fail "frontmatter above the marker was lost"
grep -q 'trailing line' "$dest" || fail "content below the marker was lost"
grep -q 'new body line two' "$dest" || fail "body was not replaced"
grep -q 'old body' "$dest" && fail "old body survived"
[[ "$(grep -c 'llmctx:begin' "$dest")" == "1" ]] || fail "marker duplicated"

# 2. A destination with NO marker gets the same marker text. One definition,
#    both paths — the asymmetry is what allowed the bug.
fresh="$tmp/fresh.md"
: >"$fresh"
sync_block "global/handoff-and-briefs.md" "$src" "$fresh"
grep -q 'synced from agent-harness/global/handoff-and-briefs.md' "$fresh" ||
  fail "creation path wrote a different marker"

# 3. Re-running is a no-op.
before="$(cat "$dest")"
sync_block "brand/voice-and-style.md" "$src" "$dest"
[[ "$before" == "$(cat "$dest")" ]] || fail "sync is not idempotent"

echo "sync-published tests: passed"
