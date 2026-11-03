#!/usr/bin/env bash
set -euo pipefail

# Managed Claude Code subagent definitions: agents/<name>.md -> <account>/agents/<name>.md
#
# Same ownership contract as skills, adapted to single files. A skill is a
# directory and carries its marker inside; an agent is one file, so the marker
# is a sidecar manifest per target directory, .llmctx-managed.json, listing the
# files this installer owns and their content hashes. A file not in the
# manifest is somebody else's and is never touched; a managed file is updated,
# or pruned when its source is gone; a source name colliding with an unmanaged
# file is a conflict, reported and left alone.
#
# Codex has no subagent format, so agents install only into Claude accounts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=bin/lib/skills.sh
source "$SCRIPT_DIR/lib/skills.sh"
# shellcheck source=bin/lib/accounts.sh
source "$SCRIPT_DIR/lib/accounts.sh"

mode=copy
account=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dev)
      mode=dev
      shift
      ;;
    --account)
      account="${2:-}"
      shift 2
      ;;
    --account=*)
      account="${1#--account=}"
      shift
      ;;
    *)
      echo "usage: llmctx agents install [--dev] [--account <name>]" >&2
      exit 2
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required to install managed agents" >&2
  exit 1
}
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
  echo "error: shasum or sha256sum is required to install managed agents" >&2
  exit 1
fi

source_revision="unknown"
source_version="unknown"
if git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  source_revision="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
  source_version="$(git -C "$SRC" describe --tags --exact-match HEAD 2>/dev/null || true)"
  [[ -n "$source_version" ]] || source_version="${source_revision:0:12}"
  if [[ -n "$(git -C "$SRC" status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then
    source_version="$source_version-dirty"
  fi
fi

# Nothing to ship is not an error: a release without agents/ simply manages
# none, and prunes whatever an earlier release installed.
source_names="$(mktemp "${TMPDIR:-/tmp}/llmctx-agent-names.XXXXXX")"
trap 'rm -f "$source_names"' EXIT
for f in "$SRC"/agents/*.md; do
  [[ -f "$f" ]] || continue
  name="$(basename "$f" .md)"
  [[ "$name" == README ]] && continue
  printf '%s\n' "$name" >>"$source_names"
done

accounts="$(llmctx_accounts_selected "$account")" || exit 1

failures=0
while IFS=$'\t' read -r account_name account_dir; do
  [[ -n "$account_name" ]] || continue
  target="$account_dir/agents"
  manifest="$target/$LLMCTX_SKILL_MARKER_NAME"
  mkdir -p "$target"
  current='{}'
  [[ -f "$manifest" ]] && current="$(jq -c '.agents // {}' "$manifest" 2>/dev/null || echo '{}')"
  next='{}'

  # Prune managed files whose source is gone.
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    grep -Fxq "$name" "$source_names" && continue
    if [[ -e "$target/$name.md" || -L "$target/$name.md" ]]; then
      rm -f "$target/$name.md"
      echo "pruned: $target/$name.md"
    fi
  done < <(jq -r 'keys[]' <<<"$current")

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    source_file="$SRC/agents/$name.md"
    destination="$target/$name.md"
    managed=0
    jq -e --arg n "$name" 'has($n)' <<<"$current" >/dev/null 2>&1 && managed=1
    if [[ -L "$destination" ]]; then
      case "$(readlink "$destination")" in
        "$SRC"/agents/*) managed=1 ;;
      esac
    fi
    if [[ -e "$destination" || -L "$destination" ]] && [[ "$managed" -eq 0 ]]; then
      echo "conflict: $destination is not managed by agent-harness" >&2
      failures=$((failures + 1))
      continue
    fi
    content_hash="$(llmctx_skill_hash_file "$source_file")"
    if [[ "$mode" == dev ]]; then
      rm -f "$destination"
      ln -s "$source_file" "$destination"
      echo "linked: $destination"
    else
      if [[ -L "$destination" ]]; then
        rm -f "$destination"
      fi
      if [[ -f "$destination" ]] && [[ "$(llmctx_skill_hash_file "$destination")" == "$content_hash" ]]; then
        echo "current: $destination"
      else
        staged="$(mktemp "$target/.llmctx-agent.XXXXXX")"
        if ! cp "$source_file" "$staged" || ! mv "$staged" "$destination"; then
          rm -f "$staged"
          failures=$((failures + 1))
          continue
        fi
        if [[ -n "$(jq -r --arg n "$name" '.[$n] // empty' <<<"$current")" ]]; then
          echo "updated: $destination ($source_version)"
        else
          echo "installed: $destination ($source_version)"
        fi
      fi
    fi
    next="$(jq -c --arg n "$name" --arg h "$content_hash" '.[$n] = {contentHash: $h}' <<<"$next")"
  done <"$source_names"

  jq -n \
    --arg managed_by "$LLMCTX_SKILL_MANAGED_BY" \
    --arg mode "$mode" \
    --arg source_revision "$source_revision" \
    --arg source_version "$source_version" \
    --argjson agents "$next" \
    '{schemaVersion:1,managedBy:$managed_by,mode:$mode,sourceRevision:$source_revision,sourceVersion:$source_version,agents:$agents}' \
    >"$manifest"
done <<<"$accounts"

[[ "$failures" -eq 0 ]] || {
  echo "agent installation completed with $failures conflict(s)" >&2
  exit 1
}
echo "agents installed in $mode mode."
