#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$SCRIPT_DIR/skill-scenarios/test_evaluate.py"
echo "skill scenario fixture/scorer tests: passed (no model evaluation run)"
