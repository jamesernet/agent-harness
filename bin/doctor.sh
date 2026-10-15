#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=bin/lib/skills.sh
source "$SCRIPT_DIR/lib/skills.sh"
# shellcheck source=bin/lib/accounts.sh
source "$SCRIPT_DIR/lib/accounts.sh"

output_json=0
quiet=0
account=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --json)
      output_json=1
      shift
      ;;
    --quiet)
      quiet=1
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
      echo "usage: llmctx doctor [--json|--quiet] [--account <name>]" >&2
      exit 2
      ;;
  esac
done

if [[ "$output_json" -eq 1 && "$quiet" -eq 1 ]]; then
  echo "usage: llmctx doctor [--json|--quiet] [--account <name>]" >&2
  exit 2
fi

# jq is required by the installer and by the normal diagnostic renderer. Keep
# its own failure path independent so doctor can still explain a missing jq.
if ! command -v jq >/dev/null 2>&1; then
  if [[ "$quiet" -eq 0 ]]; then
    if [[ "$output_json" -eq 1 ]]; then
      printf '%s\n' '{"healthy":false,"checks":[{"id":"dependency-jq","status":"FAIL","detail":"jq is not installed","remediation":"install jq, then rerun llmctx doctor"}]}'
    else
      echo "FAIL  dependency-jq           jq is not installed"
      echo "      fix: install jq, then rerun llmctx doctor"
      echo "Result: 1 check(s) failed"
    fi
  fi
  exit 1
fi

findings="$(mktemp "${TMPDIR:-/tmp}/llmctx-doctor.XXXXXX")"
skill_catalog="$(mktemp "${TMPDIR:-/tmp}/llmctx-skill-catalog.XXXXXX")"
trap 'rm -f "$findings" "$skill_catalog"' EXIT
failures=0

add_check() {
  local id="$1" status="$2" detail="$3" remediation="$4"
  jq -cn \
    --arg id "$id" \
    --arg status "$status" \
    --arg detail "$detail" \
    --arg remediation "$remediation" \
    '{id:$id,status:$status,detail:$detail,remediation:$remediation}' \
    >>"$findings"
  [[ "$status" != "FAIL" ]] || failures=$((failures + 1))
}

if command -v git >/dev/null 2>&1; then
  add_check dependency-git PASS "git is installed" ""
else
  add_check dependency-git FAIL "git is not installed" "install git, then rerun llmctx doctor"
fi
add_check dependency-jq PASS "jq is installed" ""
hash_available=1
if command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1; then
  add_check dependency-sha256 PASS "SHA-256 hashing is available" ""
else
  hash_available=0
  add_check dependency-sha256 FAIL "shasum and sha256sum are missing" "install a SHA-256 command, then rerun llmctx doctor"
fi

# Resolved before any check runs: an unreadable registry is itself the finding,
# and every account-scoped check below would otherwise report a partial machine
# as a healthy one.
accounts=""
accounts_error=""
if ! accounts="$(llmctx_accounts_selected "$account" 2>&1)"; then
  accounts_error="$accounts"
  accounts=""
fi

if [[ -n "$accounts_error" ]]; then
  add_check accounts FAIL "$accounts_error" "llmctx account list"
else
  add_check accounts PASS \
    "Claude accounts: $(printf '%s\n' "$accounts" | cut -f1 | tr '\n' ' ' | sed 's/ $//')" ""
fi

adapter_check=("$SCRIPT_DIR/build-adapters.sh" --check)
[[ -z "$account" ]] || adapter_check+=(--account "$account")
if "${adapter_check[@]}" >/dev/null 2>&1; then
  add_check adapters PASS "managed adapters and settings are current" ""
else
  add_check adapters FAIL "managed adapters or settings are missing or stale" "$SRC/install.sh"
fi

if command -v git >/dev/null 2>&1 && git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; then
  hooks_path="$(git -C "$SRC" config --get core.hooksPath || true)"
  if [[ -n "$hooks_path" ]]; then
    add_check self-git-hook FAIL "core.hooksPath is managed externally: $hooks_path" "integrate the agent-harness checks into that hook framework"
    add_check self-policy-library FAIL "policy resolver could not be verified through core.hooksPath" "integrate the policy resolver into that hook framework"
    add_check self-local-checks FAIL "local checks could not be verified through core.hooksPath" "integrate the agent-harness checks into that hook framework"
  else
    hooks_dir="$(git -C "$SRC" rev-parse --git-path hooks)"
    case "$hooks_dir" in /*) ;; *) hooks_dir="$SRC/$hooks_dir" ;; esac

    if [[ -x "$hooks_dir/pre-commit" ]] && cmp "$SCRIPT_DIR/git-hooks/pre-commit" "$hooks_dir/pre-commit" >/dev/null 2>&1; then
      add_check self-git-hook PASS "branch backstop is current" ""
    else
      add_check self-git-hook FAIL "branch backstop is missing or stale" "$SRC/install.sh"
    fi

    if [[ -f "$hooks_dir/llmctx-policy.sh" ]] && cmp "$SCRIPT_DIR/lib/policy.sh" "$hooks_dir/llmctx-policy.sh" >/dev/null 2>&1; then
      add_check self-policy-library PASS "Git hook policy resolver is current" ""
    else
      add_check self-policy-library FAIL "Git hook policy resolver is missing or stale" "$SRC/install.sh"
    fi

    if [[ -x "$hooks_dir/pre-commit.local" ]] && cmp "$SCRIPT_DIR/git-hooks/pre-commit-local.agent-harness" "$hooks_dir/pre-commit.local" >/dev/null 2>&1; then
      add_check self-local-checks PASS "repository-local checks are current" ""
    else
      add_check self-local-checks FAIL "repository-local checks are missing or stale" "$SRC/install.sh"
    fi
  fi
else
  add_check self-git-hook FAIL "agent-harness source is not a Git repository" "clone agent-harness with Git"
  add_check self-policy-library FAIL "agent-harness source is not a Git repository" "clone agent-harness with Git"
  add_check self-local-checks FAIL "agent-harness source is not a Git repository" "clone agent-harness with Git"
fi

build_skill_catalog() {
  local source_dir name source_path content_hash duplicate_names
  for source_dir in "$SRC"/skills/*/ "$SRC"/vendor/*/; do
    [[ -f "$source_dir/SKILL.md" ]] || continue
    source_dir="${source_dir%/}"
    name="$(basename "$source_dir")"
    source_path="${source_dir#"$SRC/"}"
    content_hash="$(llmctx_skill_hash "$source_dir")" || return 1
    printf '%s\t%s\t%s\t%s\n' "$name" "$source_dir" "$source_path" "$content_hash" >>"$skill_catalog"
  done
  duplicate_names="$(cut -f1 "$skill_catalog" | LC_ALL=C sort | uniq -d)"
  [[ -z "$duplicate_names" ]] || return 1
}

skill_link_is_managed() {
  local destination="$1" link_target
  [[ -L "$destination" ]] || return 1
  link_target="$(readlink "$destination")"
  case "$link_target" in
    "$SRC"/skills/* | "$SRC"/vendor/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Mirrors the installer's resolution order: an account's own key, then the
# global one, then `all`.
doctor_bundle_for_account() {
  local acct="$1" value=""
  if [[ -n "$acct" ]]; then
    value="$(git config --global --get "llmctx.skillBundle.$acct" 2>/dev/null || true)"
  fi
  [[ -n "$value" ]] ||
    value="$(git config --global --get llmctx.skillBundle 2>/dev/null || true)"
  [[ -n "$value" ]] || value=all
  printf '%s\n' "$value"
}

check_skill_target() {
  local target="$1" id="$2" bundle="${3:-all}" name source_dir source_path expected_hash destination
  local metadata_source metadata_hash metadata_mode actual_hash installed copies=0 links=0
  local issues="" expected_count=0 wanted

  # Expect only what this target's bundle installs. Counting the whole
  # catalogue made a correctly narrowed install report every deliberately
  # absent skill as "needing attention", while skill-bundle passed alongside
  # it saying those absences were on purpose.
  wanted="$(mktemp "${TMPDIR:-/tmp}/llmctx-doctor-wanted.XXXXXX")"
  llmctx_bundle_skills "$SRC" "$bundle" "$wanted"

  while IFS=$'\t' read -r name source_dir source_path expected_hash; do
    [[ -n "$name" ]] || continue
    grep -Fxq "$name" "$wanted" || continue
    expected_count=$((expected_count + 1))
    destination="$target/$name"
    if [[ -L "$destination" && "$(readlink "$destination")" == "$source_dir" ]]; then
      links=$((links + 1))
    elif llmctx_skill_is_managed_copy "$destination"; then
      metadata_source="$(jq -r '.sourcePath // ""' "$destination/$LLMCTX_SKILL_MARKER_NAME")"
      metadata_hash="$(jq -r '.contentHash // ""' "$destination/$LLMCTX_SKILL_MARKER_NAME")"
      metadata_mode="$(jq -r '.mode // ""' "$destination/$LLMCTX_SKILL_MARKER_NAME")"
      actual_hash="$(llmctx_skill_hash "$destination" 2>/dev/null || true)"
      if [[ "$metadata_source" == "$source_path" && "$metadata_hash" == "$expected_hash" &&
        "$metadata_mode" == copy && "$actual_hash" == "$expected_hash" ]]; then
        copies=$((copies + 1))
      else
        issues="${issues}${issues:+, }$name"
      fi
    else
      issues="${issues}${issues:+, }$name"
    fi
  done <"$skill_catalog"

  if [[ -d "$target" ]]; then
    for installed in "$target"/*; do
      [[ -e "$installed" || -L "$installed" ]] || continue
      name="$(basename "$installed")"
      cut -f1 "$skill_catalog" | grep -Fxq "$name" && continue
      if llmctx_skill_is_managed_copy "$installed" || skill_link_is_managed "$installed"; then
        issues="${issues}${issues:+, }$name"
      fi
    done
  fi

  rm -f "$wanted"

  if [[ -n "$issues" ]]; then
    add_check "$id" FAIL "skills needing attention: $issues" "$SRC/bin/llmctx skills install"
  elif [[ "$copies" -gt 0 && "$links" -gt 0 ]]; then
    add_check "$id" FAIL "managed skills mix copy and development modes" "$SRC/bin/llmctx skills install"
  elif [[ "$links" -eq "$expected_count" ]]; then
    add_check "$id" PASS "$links development links are current" ""
  elif [[ "$copies" -eq "$expected_count" ]]; then
    add_check "$id" PASS "$copies managed copies are current" ""
  else
    add_check "$id" FAIL "managed skill set is incomplete" "$SRC/bin/llmctx skills install"
  fi
}

if [[ "$hash_available" -eq 1 ]] && [[ -n "$accounts" ]] && build_skill_catalog; then
  # The default account keeps the bare `claude-skills` id so existing consumers
  # of --json are unaffected; additional accounts are suffixed with their name.
  while IFS=$'\t' read -r account_name account_dir; do
    [[ -n "$account_name" ]] || continue
    account_bundle="$(doctor_bundle_for_account "$account_name")"
    if [[ "$account_name" == "$LLMCTX_ACCOUNT_DEFAULT_NAME" ]]; then
      check_skill_target "$account_dir/skills" claude-skills "$account_bundle"
    else
      check_skill_target "$account_dir/skills" "claude-skills[$account_name]" "$account_bundle"
    fi
  done <<<"$accounts"
  [[ -n "$account" ]] ||
    check_skill_target "$HOME/.codex/skills" codex-skills "$(doctor_bundle_for_account "")"

  # Report the active bundle. `all` is the default and needs no comment; a
  # narrowed one does, because the whole point of narrowing is that some skills
  # are deliberately absent — and "absent on purpose" must be distinguishable
  # from "install went wrong" without reading two files to find out.
  active_bundle="$(git config --global --get llmctx.skillBundle 2>/dev/null || true)"
  [[ -n "$active_bundle" ]] || active_bundle=all
  # Per-account overrides belong in this line too, or an account narrowed on
  # purpose looks like the global one and its absences look like a bad install.
  overrides=""
  unknown=""
  while IFS=$'\t' read -r account_name _; do
    [[ -n "$account_name" ]] || continue
    account_bundle="$(git config --global --get "llmctx.skillBundle.$account_name" 2>/dev/null || true)"
    [[ -n "$account_bundle" ]] || continue
    overrides="$overrides, $account_name='$account_bundle'"
    llmctx_bundle_is_known "$SRC/skills/bundles.conf" "$account_bundle" ||
      unknown="$unknown llmctx.skillBundle.$account_name=$account_bundle"
  done <<<"$accounts"

  if [[ ! -f "$SRC/skills/bundles.conf" && "$active_bundle" != all ]]; then
    add_check skill-bundle FAIL "llmctx.skillBundle=$active_bundle but no skills/bundles.conf in this release" \
      "git config --global --unset llmctx.skillBundle"
  else
    llmctx_bundle_is_known "$SRC/skills/bundles.conf" "$active_bundle" ||
      unknown="$unknown llmctx.skillBundle=$active_bundle"
    if [[ -n "$unknown" ]]; then
      add_check skill-bundle FAIL "unknown bundle(s):$unknown" \
        "git config --global llmctx.skillBundle <name>"
    elif [[ "$active_bundle" == all && -z "$overrides" ]]; then
      add_check skill-bundle PASS "all skills install globally" ""
    else
      add_check skill-bundle PASS "bundle '$active_bundle'${overrides} — some skills are absent on purpose" ""
    fi
  fi
else
  add_check claude-skills FAIL "managed skills could not be inventoried" "$SRC/bin/llmctx skills install"
  [[ -n "$account" ]] ||
    add_check codex-skills FAIL "managed skills could not be inventoried" "$SRC/bin/llmctx skills install"
fi

if [[ "$quiet" -eq 0 ]]; then
  if [[ "$output_json" -eq 1 ]]; then
    jq -s --argjson healthy "$([[ "$failures" -eq 0 ]] && echo true || echo false)" \
      '{healthy:$healthy,checks:.}' "$findings"
  else
    while IFS= read -r finding; do
      status="$(jq -r '.status' <<<"$finding")"
      id="$(jq -r '.id' <<<"$finding")"
      detail="$(jq -r '.detail' <<<"$finding")"
      printf '%-5s %-24s %s\n' "$status" "$id" "$detail"
      remediation="$(jq -r '.remediation' <<<"$finding")"
      [[ -z "$remediation" ]] || printf '      fix: %s\n' "$remediation"
    done <"$findings"
    if [[ "$failures" -eq 0 ]]; then
      echo "Result: healthy"
    else
      echo "Result: $failures check(s) failed"
    fi
  fi
fi

[[ "$failures" -eq 0 ]]
