#!/usr/bin/env bash
set -euo pipefail

# Lint skills/*/SKILL.md so malformed skills are caught before they silently
# degrade triggering:
#   - SKILL.md exists
#   - YAML frontmatter present and terminated (--- ... ---)
#   - `name` present and matching the directory name
#   - `description` present and <= MAX_DESC characters
#   - cross-skill relative links resolve
#   - STUB-marked skills must have disable-model-invocation: true
# Plus: duplicate-name and vendor presence checks, JSON validation, and bash -n
# on every owned shell script.
# Used by .github/workflows/ci.yml and this repo's pre-commit.local.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
MAX_DESC=1024

fail=0
err() {
  echo "lint: $1: $2" >&2
  fail=1
}

for dir in "$SRC"/skills/*/; do
  name="$(basename "$dir")"
  f="$dir/SKILL.md"
  if [ ! -f "$f" ]; then
    err "$name" "missing SKILL.md"
    continue
  fi
  if [ "$(head -1 "$f")" != "---" ]; then
    err "$name" "no YAML frontmatter (first line must be ---)"
    continue
  fi

  closed="$(awk 'NR==1 && $0=="---" {infm=1; next} infm && $0=="---" {print "yes"; exit}' "$f")"
  if [ "$closed" != "yes" ]; then
    err "$name" "frontmatter never terminated (missing closing ---)"
    continue
  fi

  fm="$(awk 'NR==1 && $0=="---" {infm=1; next} infm && $0=="---" {exit} infm' "$f")"
  fm_name="$(printf '%s\n' "$fm" | sed -n 's/^name:[[:space:]]*//p' | head -1)"
  desc="$(printf '%s\n' "$fm" | sed -n 's/^description:[[:space:]]*//p' | head -1)"

  [ -n "$fm_name" ] || err "$name" "frontmatter has no name"
  [ -n "$desc" ] || err "$name" "frontmatter has no description"
  if [ -n "$fm_name" ] && [ "$fm_name" != "$name" ]; then
    err "$name" "name \"$fm_name\" does not match directory name"
  fi
  if [ -n "$desc" ] && [ "${#desc}" -gt "$MAX_DESC" ]; then
    err "$name" "description is ${#desc} chars (max $MAX_DESC)"
  fi

  # Relative links between skills must resolve (to skills/ or vendor/).
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    [ -d "$SRC/skills/$target" ] || [ -d "$SRC/vendor/$target" ] ||
      err "$name" "broken link ../$target/"
  done < <(grep -o '](\.\./[a-z0-9-]*/' "$f" 2>/dev/null | sed 's/](\.\.\///; s/\/$//' | sort -u || true)

  # A stub body must not be auto-invocable — half-fires are worse than nothing.
  if grep -qi 'STUB' "$f" && ! printf '%s\n' "$fm" | grep -q 'disable-model-invocation: true'; then
    err "$name" "marked STUB but model invocation is enabled"
  fi
done

# vendor/ is third-party: presence-only, no house conventions enforced.
for dir in "$SRC"/vendor/*/; do
  [ -f "$dir/SKILL.md" ] || err "vendor/$(basename "$dir")" "missing SKILL.md"
done

# A flat install target cannot represent duplicate names across owned and
# vendored skills without one silently replacing the other.
duplicate_names="$(
  find "$SRC/skills" "$SRC/vendor" -mindepth 2 -maxdepth 2 -name SKILL.md -print |
    sed 's#/SKILL.md$##' | awk -F/ '{print $NF}' | LC_ALL=C sort | uniq -d
)"
if [ -n "$duplicate_names" ]; then
  while IFS= read -r name; do err "$name" "duplicate skill name"; done <<<"$duplicate_names"
fi

# Every owned skill must belong to at least one bundle. install-skills.sh only
# warns the other way (a bundle naming a skill that does not ship), so without
# this an added skill silently installs under `all` and nowhere else.
bundles_file="$SRC/skills/bundles.conf"
if [ -f "$bundles_file" ]; then
  for dir in "$SRC"/skills/*/; do
    name="$(basename "$dir")"
    [ -f "$dir/SKILL.md" ] || continue
    grep -q "^[a-z0-9-]*|${name}\$" "$bundles_file" ||
      err "$name" "in no bundle (add a line to skills/bundles.conf)"
  done
else
  err "skills/bundles.conf" "missing"
fi

# Agents: agents/<name>.md must be a loadable subagent definition. A bad model
# alias or a non-numeric turn budget is silently ignored by the runtime, which
# is exactly how a cost control stops controlling anything.
for f in "$SRC"/agents/*.md; do
  [ -f "$f" ] || continue
  name="$(basename "$f" .md)"
  [ "$name" = README ] && continue
  if [ "$(head -1 "$f")" != "---" ]; then
    err "agents/$name" "no YAML frontmatter (first line must be ---)"
    continue
  fi
  fm="$(awk 'NR==1 && $0=="---" {infm=1; next} infm && $0=="---" {exit} infm' "$f")"
  fm_name="$(printf '%s\n' "$fm" | sed -n 's/^name:[[:space:]]*//p' | head -1)"
  desc="$(printf '%s\n' "$fm" | sed -n 's/^description:[[:space:]]*//p' | head -1)"
  model="$(printf '%s\n' "$fm" | sed -n 's/^model:[[:space:]]*//p' | head -1)"
  effort="$(printf '%s\n' "$fm" | sed -n 's/^effort:[[:space:]]*//p' | head -1)"
  turns="$(printf '%s\n' "$fm" | sed -n 's/^maxTurns:[[:space:]]*//p' | head -1)"
  [ "$fm_name" = "$name" ] || err "agents/$name" "name \"$fm_name\" does not match file name"
  [ -n "$desc" ] || err "agents/$name" "frontmatter has no description"
  [ -n "$model" ] || err "agents/$name" "no model: pinning the model is the point of shipping an agent"
  case "$model" in
    '' | sonnet | opus | haiku | fable | inherit | claude-*) ;;
    *) err "agents/$name" "model \"$model\" is not an alias or a claude-* id" ;;
  esac
  case "$effort" in
    '' | low | medium | high | xhigh | max) ;;
    *) err "agents/$name" "effort \"$effort\" is not low|medium|high|xhigh|max" ;;
  esac
  case "$turns" in
    '' | *[!0-9]*) [ -z "$turns" ] || err "agents/$name" "maxTurns \"$turns\" is not an integer" ;;
  esac
done

# Every owned JSON document parses.
while IFS= read -r json_file; do
  jq empty "$json_file" >/dev/null 2>&1 || err "${json_file#"$SRC/"}" "invalid JSON"
done < <(find "$SRC" -path "$SRC/vendor" -prune -o -type f -name '*.json' -print)

# Every owned shell script parses, including extensionless Git hooks.
while IFS= read -r s; do
  [ -f "$s" ] || continue
  bash -n "$s" || err "$(basename "$s")" "syntax error"
done < <(find "$SRC/bin" "$SRC/tests" -type f \( -name '*.sh' -o -path '*/git-hooks/*' \) -print)

[ "$fail" -eq 0 ] || exit 1
echo "lint: all skills and agents OK"
