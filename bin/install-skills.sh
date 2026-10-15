#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=bin/lib/skills.sh
source "$SCRIPT_DIR/lib/skills.sh"
# shellcheck source=bin/lib/accounts.sh
source "$SCRIPT_DIR/lib/accounts.sh"

mode=copy
bundle_opt=""
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
    --bundle)
      bundle_opt="${2:-}"
      shift 2
      ;;
    --bundle=*)
      bundle_opt="${1#--bundle=}"
      shift
      ;;
    *)
      echo "usage: llmctx skills install [--dev] [--bundle <name>] [--account <name>]" >&2
      exit 2
      ;;
  esac
done

# The chosen bundle is machine state, not repository state, so it lives in
# global git config alongside the other llmctx.* keys rather than in a file this
# repository would then have to gitignore. Without it, `llmctx install` would
# silently widen the set back to `all` on the next run — which is exactly the
# failure that makes people stop trusting a narrowing tool.
#
# Resolution is per account, because one machine runs accounts with genuinely
# different needs — a fintech backend and a marketing site share almost nothing.
# A single global key would let a plain `llmctx install` re-apply one account's
# choice to every other account, which is the same silent widening one level up.
bundle_for_account() {
  local acct="$1" value=""
  if [[ -n "$bundle_opt" ]]; then
    printf '%s\n' "$bundle_opt"
    return
  fi
  if [[ -n "$acct" ]]; then
    value="$(git config --global --get "llmctx.skillBundle.$acct" 2>/dev/null || true)"
  fi
  [[ -n "$value" ]] ||
    value="$(git config --global --get llmctx.skillBundle 2>/dev/null || true)"
  [[ -n "$value" ]] || value=all
  printf '%s\n' "$value"
}

command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required to install managed skills" >&2
  exit 1
}
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
  echo "error: shasum or sha256sum is required to install managed skills" >&2
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

is_managed_link() {
  local destination="$1" link_target
  [[ -L "$destination" ]] || return 1
  link_target="$(readlink "$destination")"
  case "$link_target" in
    "$SRC"/skills/* | "$SRC"/vendor/*) return 0 ;;
    *) return 1 ;;
  esac
}

replace_managed_destination() {
  local staged="$1" destination="$2" backup_root
  backup_root="$(mktemp -d "$(dirname "$destination")/.llmctx-backup.XXXXXX")" || return 1
  if ! mv "$destination" "$backup_root/skill"; then
    rmdir "$backup_root"
    return 1
  fi
  if mv "$staged" "$destination"; then
    rm -rf "$backup_root"
  else
    mv "$backup_root/skill" "$destination" || return 1
    rmdir "$backup_root" || return 1
    return 1
  fi
}

install_copy() {
  local source_dir="$1" destination="$2" source_path="$3" content_hash staged
  if [[ -L "$destination" ]]; then
    if ! is_managed_link "$destination"; then
      echo "conflict: $destination is an unmanaged symlink" >&2
      return 1
    fi
  elif [[ -e "$destination" ]] && ! llmctx_skill_is_managed_copy "$destination"; then
    echo "conflict: $destination is not managed by agent-harness" >&2
    return 1
  fi

  content_hash="$(llmctx_skill_hash "$source_dir")" || return 1
  staged="$(mktemp -d "$(dirname "$destination")/.llmctx-skill.XXXXXX")" || return 1
  cp -R "$source_dir/." "$staged/" || {
    rm -rf "$staged"
    return 1
  }
  if ! jq -n \
    --arg managed_by "$LLMCTX_SKILL_MANAGED_BY" \
    --arg source_path "$source_path" \
    --arg source_revision "$source_revision" \
    --arg source_version "$source_version" \
    --arg content_hash "$content_hash" \
    '{schemaVersion:1,managedBy:$managed_by,mode:"copy",sourcePath:$source_path,sourceRevision:$source_revision,sourceVersion:$source_version,contentHash:$content_hash}' \
    >"$staged/$LLMCTX_SKILL_MARKER_NAME"; then
    rm -rf "$staged"
    return 1
  fi

  if [[ -e "$destination" || -L "$destination" ]]; then
    replace_managed_destination "$staged" "$destination" || return 1
    echo "updated: $destination ($source_version)"
  else
    mv "$staged" "$destination" || return 1
    echo "installed: $destination ($source_version)"
  fi
}

install_dev_link() {
  local source_dir="$1" destination="$2"
  if [[ -L "$destination" ]]; then
    if is_managed_link "$destination"; then
      ln -sfn "$source_dir" "$destination" || return 1
      echo "linked: $destination"
      return
    fi
    echo "conflict: $destination is an unmanaged symlink" >&2
    return 1
  elif [[ -e "$destination" ]]; then
    if llmctx_skill_is_managed_copy "$destination"; then
      rm -rf "$destination" || return 1
    else
      echo "conflict: $destination is not managed by agent-harness" >&2
      return 1
    fi
  fi
  ln -s "$source_dir" "$destination" || return 1
  echo "linked: $destination"
}

skill_names="$(mktemp "${TMPDIR:-/tmp}/llmctx-skill-names.XXXXXX")"
available="$(mktemp "${TMPDIR:-/tmp}/llmctx-skill-avail.XXXXXX")"
seen_bundles="$(mktemp "${TMPDIR:-/tmp}/llmctx-skill-seen.XXXXXX")"
trap 'rm -f "$skill_names" "$available" "$seen_bundles"' EXIT
for source_dir in "$SRC"/skills/*/ "$SRC"/vendor/*/; do
  [[ -f "$source_dir/SKILL.md" ]] || continue
  basename "$source_dir" >>"$available"
done

bundles_file="$SRC/skills/bundles.conf"

# An unknown bundle must fail loudly and change nothing, so every target's
# bundle is validated before the first install prunes anything.
validate_bundle() {
  local spec="$1" b
  [[ "$spec" == all ]] && return 0
  [[ -f "$bundles_file" ]] || {
    echo "error: no $bundles_file" >&2
    exit 1
  }
  # Validate each name in a comma-separated list BEFORE resolving any of them.
  # Resolving an unknown name to the empty set would prune every installed
  # skill over one missing letter. Validating the joined string instead of its
  # parts is what made `webapp,fintech` report itself as an unknown bundle.
  llmctx_bundle_is_known "$bundles_file" "$spec" || {
    echo "error: unknown bundle in '$spec'" >&2
    echo "available: $(grep -v '^#' "$bundles_file" | grep -v '^$' | cut -d'|' -f1 | sort -u | tr '\n' ' ')all" >&2
    exit 2
  }
}

# Resolve one bundle spec into $skill_names.
resolve_skills() {
  local spec="$1" b want
  : >"$skill_names"
  : >"$seen_bundles"
  if [[ "$spec" == all ]]; then
    cp "$available" "$skill_names"
    LC_ALL=C sort -o "$skill_names" "$skill_names"
    return
  fi
  # A bundle naming a skill this release does not ship is a stale bundles.conf,
  # not a reason to fail the install — report it and carry on.
  : >"$seen_bundles"
  IFS=',' read -r -a bundle_list <<<"$spec"
  for b in "${bundle_list[@]}"; do
    llmctx_bundle_expand "$bundles_file" "$b" "$seen_bundles" "$skill_names"
  done
  while IFS= read -r want; do
    grep -qxF "$want" "$available" || echo "warning: bundle names unknown skill '$want'" >&2
  done < <(LC_ALL=C sort -u "$skill_names")
  llmctx_bundle_skills "$SRC" "$spec" "$skill_names"
}

# Duplicates are checked against the WHOLE catalogue, not the selected set: the
# namespace is flat across skills/ and vendor/, so a collision is a packaging
# fault regardless of which bundle is installed today. Checking only the
# selection would let one ship and surface later, for whoever first picks a
# bundle containing both.
duplicate_names="$(LC_ALL=C sort "$available" | uniq -d)"
[[ -z "$duplicate_names" ]] || {
  echo "error: duplicate skill names:" >&2
  echo "$duplicate_names" >&2
  exit 1
}

# One skills directory per registered Claude account, because the alternative
# is a machine where `llmctx skills install` reports success and one account
# has no skills at all — which is the state this replaced.
accounts="$(llmctx_accounts_selected "$account")" || exit 1
targets=()
target_accounts=()
while IFS=$'\t' read -r account_name account_dir; do
  [[ -n "$account_name" ]] || continue
  targets+=("$account_dir/skills")
  target_accounts+=("$account_name")
done <<<"$accounts"
# Codex has no config-directory switching, so it gets one copy — and a run
# narrowed to a single Claude account is not about Codex at all. It has no
# account of its own, so it follows the global key.
if [[ -z "$account" ]]; then
  targets+=("$HOME/.codex/skills")
  target_accounts+=("")
fi

# Validate every target's bundle up front: a typo on the second account must
# not leave the first one already pruned.
for i in "${!targets[@]}"; do
  validate_bundle "$(bundle_for_account "${target_accounts[$i]}")"
done

failures=0
for i in "${!targets[@]}"; do
  target="${targets[$i]}"
  target_bundle="$(bundle_for_account "${target_accounts[$i]}")"
  resolve_skills "$target_bundle"
  if [[ "$target_bundle" != all ]]; then
    echo "bundle: $target_bundle ($(wc -l <"$skill_names" | tr -d ' ') of $(wc -l <"$available" | tr -d ' ') skills)${target_accounts[$i]:+ [${target_accounts[$i]}]}"
  fi
  mkdir -p "$target"

  for installed in "$target"/*; do
    [[ -e "$installed" || -L "$installed" ]] || continue
    name="$(basename "$installed")"
    grep -Fxq "$name" "$skill_names" && continue
    if is_managed_link "$installed"; then
      rm "$installed"
      echo "pruned: $installed"
    elif llmctx_skill_is_managed_copy "$installed"; then
      rm -rf "$installed"
      echo "pruned: $installed"
    fi
  done

  for source_dir in "$SRC"/skills/*/ "$SRC"/vendor/*/; do
    [[ -f "$source_dir/SKILL.md" ]] || continue
    source_dir="${source_dir%/}"
    name="$(basename "$source_dir")"
    grep -Fxq "$name" "$skill_names" || continue
    source_path="${source_dir#"$SRC/"}"
    destination="$target/$name"
    if [[ "$mode" == dev ]]; then
      install_dev_link "$source_dir" "$destination" || failures=$((failures + 1))
    else
      install_copy "$source_dir" "$destination" "$source_path" || failures=$((failures + 1))
    fi
  done
done

[[ "$failures" -eq 0 ]] || {
  echo "skill installation completed with $failures conflict(s)" >&2
  exit 1
}
echo "skills installed in $mode mode."
