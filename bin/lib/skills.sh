# shellcheck shell=bash
LLMCTX_SKILL_MARKER_NAME=".llmctx-managed.json"
# FROZEN at the pre-rename value, deliberately. llmctx_skill_is_managed_copy()
# compares this string for exact equality against .llmctx-managed.json in every
# installed skill. Changing it to jamesernet/agent-harness would make every
# skill already installed in a consumer repo read as unmanaged, and the
# installer would refuse to touch it. This is a protocol identifier like
# llmctx-hook and the llmctx:begin markers, not a label — see ADR-001,
# https://github.com/jamesernet/agent-harness/issues/21.
LLMCTX_SKILL_MANAGED_BY="jamesernet/llm-context"

llmctx_skill_hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

llmctx_skill_hash_stream() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

llmctx_skill_hash() {
  local source_dir="$1"
  (
    cd "$source_dir" || exit 1
    find . -type f ! -name "$LLMCTX_SKILL_MARKER_NAME" -print | LC_ALL=C sort |
      while IFS= read -r file; do
        printf '%s\n' "$file"
        llmctx_skill_hash_file "$file"
      done
  ) | llmctx_skill_hash_stream
}

llmctx_skill_is_managed_copy() {
  local destination="$1"
  [[ -f "$destination/$LLMCTX_SKILL_MARKER_NAME" ]] &&
    jq -e --arg managed_by "$LLMCTX_SKILL_MANAGED_BY" '.managedBy == $managed_by' \
      "$destination/$LLMCTX_SKILL_MARKER_NAME" >/dev/null 2>&1
}

# Bundle resolution lives here because the installer and doctor must agree on
# what a bundle means. Two copies of this logic would drift, and doctor would
# then report a correctly narrowed install as broken.
llmctx_bundle_expand() {
  local bundles_file="$1" bundle="$2" seen="$3" out="$4" name skill
  grep -qxF "$bundle" "$seen" 2>/dev/null && return 0
  printf '%s\n' "$bundle" >>"$seen"
  while IFS='|' read -r name skill; do
    [[ "$name" == "$bundle" ]] || continue
    case "$skill" in
      '+'*) llmctx_bundle_expand "$bundles_file" "${skill#+}" "$seen" "$out" ;;
      '') ;;
      *) printf '%s\n' "$skill" >>"$out" ;;
    esac
  done <"$bundles_file"
}

llmctx_bundle_is_known() {
  local bundles_file="$1" spec="$2" b list
  [[ "$spec" == all ]] && return 0
  [[ -f "$bundles_file" ]] || return 1
  IFS=',' read -r -a list <<<"$spec"
  for b in "${list[@]}"; do
    grep -qE "^${b}\|" "$bundles_file" || return 1
  done
  return 0
}

# The reserved bundle whose members `all` subtracts. A skill that bills a
# third-party API per run must not arrive because nobody chose a bundle: opt-in
# is enforced here rather than asserted in the skill's own prose. Naming the
# bundle still installs them, and a spec that names anything is never filtered.
LLMCTX_METERED_BUNDLE=metered

# Removes every member of the metered bundle from the name file <names>, in
# place. A bundles.conf with no metered block leaves the file untouched.
llmctx_bundle_drop_metered() {
  local bundles_file="$1" names="$2" metered seen kept
  [[ -f "$bundles_file" ]] || return 0
  metered="$(mktemp "${TMPDIR:-/tmp}/llmctx-metered.XXXXXX")"
  seen="$(mktemp "${TMPDIR:-/tmp}/llmctx-metered-seen.XXXXXX")"
  kept="$(mktemp "${TMPDIR:-/tmp}/llmctx-metered-kept.XXXXXX")"
  llmctx_bundle_expand "$bundles_file" "$LLMCTX_METERED_BUNDLE" "$seen" "$metered"
  LC_ALL=C sort -u "$metered" -o "$metered"
  if [[ -s "$metered" ]]; then
    LC_ALL=C sort -u "$names" -o "$names"
    comm -23 "$names" "$metered" >"$kept"
    cat "$kept" >"$names"
  fi
  rm -f "$metered" "$seen" "$kept"
}

# Which skills a bundle spec installs, one name per line, into <out>.
llmctx_bundle_skills() {
  local src="$1" spec="$2" out="$3"
  local bundles_file="$src/skills/bundles.conf"
  local available seen raw dir b list
  available="$(mktemp "${TMPDIR:-/tmp}/llmctx-bundle-avail.XXXXXX")"
  seen="$(mktemp "${TMPDIR:-/tmp}/llmctx-bundle-seen.XXXXXX")"
  raw="$(mktemp "${TMPDIR:-/tmp}/llmctx-bundle-raw.XXXXXX")"
  for dir in "$src"/skills/*/ "$src"/vendor/*/; do
    [[ -f "$dir/SKILL.md" ]] || continue
    basename "$dir" >>"$available"
  done
  LC_ALL=C sort -u "$available" -o "$available"
  if [[ "$spec" == all ]]; then
    cp "$available" "$out"
    llmctx_bundle_drop_metered "$bundles_file" "$out"
  else
    IFS=',' read -r -a list <<<"$spec"
    for b in "${list[@]}"; do
      llmctx_bundle_expand "$bundles_file" "$b" "$seen" "$raw"
    done
    LC_ALL=C sort -u "$raw" -o "$raw"
    comm -12 "$raw" "$available" >"$out"
  fi
  rm -f "$available" "$seen" "$raw"
}
