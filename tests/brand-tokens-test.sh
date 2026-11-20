#!/usr/bin/env bash
# Browser fixtures are deterministic; public reference-site checks are attended.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$SCRIPT_DIR/../skills/site-visual-baseline/scripts"
if ! command -v node >/dev/null 2>&1 || ! node "$PACK/runtime.mjs" --check >/dev/null 2>&1; then
  echo "brand-token tests: skipped (run node skills/site-visual-baseline/scripts/runtime.mjs --install)"
  [[ -z "${CI:-}" ]] || exit 1
  exit 0
fi
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-0}"
node --test "$SCRIPT_DIR/brand-tokens.test.mjs"
echo "brand-token tests: passed"
