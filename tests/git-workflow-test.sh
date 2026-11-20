#!/usr/bin/env bash
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generator="${1:-$SRC/bin/build-adapters.sh}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-git-reference.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fixture="$tmp/source with spaces"
mkdir -p "$fixture" "$tmp/home"
cp -R "$SRC/bin" "$SRC/global" "$SRC/claude" "$fixture/"
cp "$generator" "$fixture/bin/build-adapters.sh"
export HOME="$tmp/home" GIT_CONFIG_GLOBAL="$tmp/global.gitconfig" GIT_CONFIG_NOSYSTEM=1
: >"$GIT_CONFIG_GLOBAL"
git init -q "$fixture"
reference="$fixture/global/git-workflow.md"
printf '\nGit-procedure-detail-sentinel\n' >>"$reference"
"$fixture/bin/build-adapters.sh" >/dev/null
python3 - "$fixture" "$HOME" <<'PY'
from pathlib import Path
import re
import sys
source, home = map(Path, sys.argv[1:])
for file in [home / '.claude/CLAUDE.md', home / '.codex/AGENTS.md']:
    text = file.read_text()
    match = re.search(r'\[Git workflow\]\(<([^>]+)>\)', text)
    assert match, f'{file.name}: no reachable Git workflow locator'
    target = Path(match.group(1))
    assert target.resolve() == (source / 'global/git-workflow.md').resolve()
    assert 'Git-procedure-detail-sentinel' in target.read_text()
    loaded = text + ''.join(Path(line[1:]).read_text() for line in text.splitlines() if line.startswith('@'))
    assert 'Git-procedure-detail-sentinel' not in loaded, 'procedures were loaded unconditionally'
PY
"$fixture/bin/build-adapters.sh" --check >/dev/null
cp "$HOME/.claude/CLAUDE.md" "$tmp/claude-before"
cp "$HOME/.codex/AGENTS.md" "$tmp/codex-before"

refuse_unusable_reference() {
  for flag in '' --check; do
    if "$fixture/bin/build-adapters.sh" ${flag:+"$flag"} >"$tmp/refusal.log" 2>&1; then
      echo "Git workflow test failed: unusable reference accepted ($flag)" >&2
      exit 1
    fi
  done
  cmp "$HOME/.claude/CLAUDE.md" "$tmp/claude-before"
  cmp "$HOME/.codex/AGENTS.md" "$tmp/codex-before"
}

mv "$reference" "$tmp/reference-backup"
refuse_unusable_reference
cp "$tmp/reference-backup" "$reference"
: >"$reference"
refuse_unusable_reference
cp "$tmp/reference-backup" "$reference"
if [[ "$(id -u)" != 0 ]]; then
  chmod 000 "$reference"
  refuse_unusable_reference
  chmod 600 "$reference"
fi
echo "Git workflow delivery and fail-closed reference checks: passed"
