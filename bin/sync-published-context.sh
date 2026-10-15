#!/usr/bin/env bash
set -euo pipefail

# Sync intentionally public context into existing website repositories.
# This is separate from local adapter installation: missing consumer repos are
# skipped during a normal sync and are never created as side effects.
#
#   bin/sync-published-context.sh           sync repositories that exist
#   bin/sync-published-context.sh --check   report drift; missing repos fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
MODE="${1:-sync}"

case "$MODE" in
  sync | --check) ;;
  *)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac

# The GitHub org is emergent-possibilities, but both machines deliberately use
# the stable local brand path ~/repos/github.com/emergentlabs/. Git remotes own
# the org mapping; publication, Git includeIf rules, and other path-based tools
# need the local path to remain consistent across machines.
#
# source | consumer repo root | target path relative to consumer root
SYNC_MAP=(
  "brand/about-me.md|$HOME/repos/github.com/emergentlabs/jamesernet.com|docs/knowledge/profile/about-me.md"
  "brand/voice-and-style.md|$HOME/repos/github.com/emergentlabs/jamesernet.com|docs/knowledge/principles/voice-and-style.md"
  "brand/about-me.md|$HOME/repos/github.com/emergentlabs/emergentlabs.xyz|docs/context/about-me.md"
  "brand/voice-and-style.md|$HOME/repos/github.com/emergentlabs/emergentlabs.xyz|docs/context/voice-and-style.md"
  "brand/about-me.md|$HOME/repos/github.com/emergentlabs/jamesernet.com|lib/personal-context.md"
  "brand/voice-and-style.md|$HOME/repos/github.com/emergentlabs/jamesernet.com|lib/voice-and-style.md"
  "global/behavioral-guidelines.md|$HOME/repos/github.com/emergentlabs/jamesernet.com|lib/agent-rules-behavioral.md"
  "global/communication-style.md|$HOME/repos/github.com/emergentlabs/jamesernet.com|lib/agent-rules-communication.md"
  "global/handoff-and-briefs.md|$HOME/repos/github.com/emergentlabs/jamesernet.com|lib/agent-rules-handoff.md"
)

extract_block() {
  awk '/llmctx:begin/{f=1;next} /llmctx:end/{f=0} f' "$1"
}

sync_block() {
  local source_rel="$1" src="$2" dest="$3" dest_dir tmp
  dest_dir="$(dirname "$dest")"
  mkdir -p "$dest_dir"
  tmp="$(mktemp "$dest_dir/.llmctx-publish.XXXXXX")"
  # shellcheck disable=SC2064 # expand $tmp now, not at trap time
  trap "rm -f '$tmp'" RETURN

  if grep -q "llmctx:begin" "$dest" 2>/dev/null; then
    awk -v srcfile="$src" '
      function emit(){ while ((getline l < srcfile) > 0) print l; close(srcfile) }
      /llmctx:begin/ { print; emit(); inblk=1; next }
      /llmctx:end/   { inblk=0; print; next }
      !inblk { print }
    ' "$dest" >"$tmp"
  else
    {
      echo "<!-- llmctx:begin — synced from agent-harness/$source_rel; edit there, then run bin/sync-published-context.sh. Do not edit between these markers. -->"
      cat "$src"
      echo "<!-- llmctx:end -->"
    } >"$tmp"
  fi

  mv "$tmp" "$dest"
}

result=0
for entry in "${SYNC_MAP[@]}"; do
  IFS='|' read -r source_rel repo_root target_rel <<<"$entry"
  src="$SRC/$source_rel"
  dest="$repo_root/$target_rel"

  if ! git -C "$repo_root" rev-parse --show-toplevel >/dev/null 2>&1; then
    if [[ "$MODE" == "--check" ]]; then
      echo "missing consumer repo: $repo_root" >&2
      result=1
    else
      echo "skipped: $repo_root (not cloned)"
    fi
    continue
  fi

  if [[ "$MODE" == "--check" ]]; then
    if [[ ! -f "$dest" ]] || ! diff <(extract_block "$dest") "$src" >/dev/null 2>&1; then
      echo "drift: $dest"
      result=1
    fi
  else
    sync_block "$source_rel" "$src" "$dest"
    echo "synced: $source_rel -> $dest"
  fi
done

if [[ "$result" -ne 0 ]]; then
  echo "published context is out of sync." >&2
  exit 1
fi

if [[ "$MODE" == "--check" ]]; then
  echo "all published context is in sync."
fi
