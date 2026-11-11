#!/usr/bin/env bash
set -euo pipefail

# Replace the vendored Cloudflare skills with an explicitly selected upstream
# tag or commit and update vendor.lock.json with the resolved immutable SHA.

[[ "$#" -eq 1 ]] || {
  echo "usage: bin/update-vendor.sh <tag-or-commit>" >&2
  exit 2
}
REF="$1"
case "$REF" in
  main | master | HEAD)
    echo "error: use an immutable commit or a deliberate release tag, not $REF" >&2
    exit 2
    ;;
esac
UPSTREAM="https://github.com/cloudflare/skills"
# Only what a bundle actually installs. Eleven skills were vendored for a
# `cloudflare` bundle no account ever activated, while the Cloudflare plugin
# keeps the full current set in ~/.claude/skills on its own; the one skill in
# use is web-perf, through the website bundle. Decided on issue #36.
SKILLS=(web-perf)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=bin/lib/vendor.sh
source "$SCRIPT_DIR/lib/vendor.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git clone --quiet "$UPSTREAM" "$tmp/upstream"
git -C "$tmp/upstream" checkout --quiet "$REF"

pin="$(git -C "$tmp/upstream" rev-parse HEAD)"
prepared="$tmp/vendor"
mkdir -p "$prepared"
cp "$SRC/vendor/README.md" "$prepared/README.md"

for s in "${SKILLS[@]}"; do
  [ -d "$tmp/upstream/skills/$s" ] || {
    echo "upstream no longer has $s — handle manually" >&2
    exit 1
  }
  cp -R "$tmp/upstream/skills/$s" "$prepared/$s"
  echo "updated: vendor/$s"
done

backup="$SRC/.vendor-backup.$$"
[[ ! -e "$backup" ]] || {
  echo "error: backup path already exists: $backup" >&2
  exit 1
}
mv "$SRC/vendor" "$backup"
if mv "$prepared" "$SRC/vendor"; then
  rm -rf "$backup"
else
  mv "$backup" "$SRC/vendor"
  exit 1
fi

content_hash="$(llmctx_vendor_hash "$SRC/vendor")"
skills_json="$(printf '%s\n' "${SKILLS[@]}" | jq -R . | jq -s .)"
lock_tmp="$(mktemp "$SRC/.vendor-lock.XXXXXX")"
jq -n \
  --arg repository "$UPSTREAM" \
  --arg commit "$pin" \
  --arg content_hash "$content_hash" \
  --arg recorded_at "$(date -u +%Y-%m-%d)" \
  --argjson skills "$skills_json" \
  '{schemaVersion:1,sources:[{name:"cloudflare-skills",repository:$repository,commit:$commit,contentSha256:$content_hash,recordedAt:$recorded_at,skills:$skills}]}' \
  >"$lock_tmp"
mv "$lock_tmp" "$SRC/vendor.lock.json"

bash "$SCRIPT_DIR/lint-skills.sh"
"$SCRIPT_DIR/check-vendor-lock.sh"
echo
echo "pinned commit: $pin — review git diff, then commit."
