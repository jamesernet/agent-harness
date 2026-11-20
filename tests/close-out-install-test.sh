#!/usr/bin/env bash
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-close-out-install.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" GIT_CONFIG_GLOBAL="$tmp/global" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
: >"$GIT_CONFIG_GLOBAL"
"$SRC/bin/install-skills.sh" --bundle core >/dev/null
for provider in claude codex; do
  installed="$HOME/.$provider/skills/close-out"
  cmp "$SRC/skills/close-out/SKILL.md" "$installed/SKILL.md"
  cmp "$SRC/skills/close-out/agents/openai.yaml" "$installed/agents/openai.yaml"
  [[ -f "$installed/.llmctx-managed.json" ]]
  [[ -f "$HOME/.$provider/skills/handoff/SKILL.md" ]]
  [[ -f "$HOME/.$provider/skills/start-a-session/SKILL.md" ]]
done
echo "close-out core-bundle delivery and invocation metadata: passed"
