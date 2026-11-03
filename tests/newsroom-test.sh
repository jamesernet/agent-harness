#!/usr/bin/env bash
# The persona newsroom template ships its own pytest suite. Run it under uv when
# uv is on PATH; otherwise say so and pass, so a missing uv reads as a skip, not
# as a green run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$SCRIPT_DIR/../templates/newsroom"

if ! command -v uv >/dev/null 2>&1; then
  echo "newsroom tests: skipped (uv not on PATH)"
  exit 0
fi

uv run --quiet --directory "$PACK" --locked --extra anthropic pytest -q
echo "newsroom tests: passed"
