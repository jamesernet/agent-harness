# shellcheck shell=bash
# Provider accounts: one config directory per login.
#
# Claude Code keys its credential store by CLAUDE_CONFIG_DIR, so a second
# directory is a second, fully independent login rather than a swapped token.
# That is how one machine works across two organisations while keeping
# connectors and Remote Control working in both.
#
# NOT a repository policy profile. `llmctx explain profile` answers
# personal|client and describes a REPOSITORY; an account describes which Claude
# login a session runs on. Different axis, deliberately different word.
#
# The registry is machine state, not repository state, so it lives in global Git
# config beside llmctx.skillBundle:
#
#   git config --global --add llmctx.claudeAccount acme=~/.claude-acme
#   git config --global --add llmctx.codexAccount acme=~/.codex-acme
#
# $HOME/.claude and $HOME/.codex are always installed into, as `default`,
# registered or not.
# Registration is purely additive. A list that could omit the primary would
# reintroduce the failure this exists to fix: an install that silently skips a
# config directory and reports success.

LLMCTX_ACCOUNT_KEY="llmctx.claudeAccount"
LLMCTX_ACCOUNT_DEFAULT_NAME="default"

llmctx_account_validate_provider() {
  case "$1" in
    claude | codex) ;;
    *)
      echo "error: provider '$1' must be claude or codex" >&2
      return 1
      ;;
  esac
}

llmctx_account_key() {
  local provider="${1:-claude}"
  llmctx_account_validate_provider "$provider" || return 1
  case "$provider" in
    claude) printf '%s\n' "$LLMCTX_ACCOUNT_KEY" ;;
    codex) printf '%s\n' "llmctx.codexAccount" ;;
  esac
}

llmctx_account_default_dir() {
  local provider="${1:-claude}"
  llmctx_account_validate_provider "$provider" || return 1
  case "$provider" in
    claude) printf '%s\n' "$HOME/.claude" ;;
    codex) printf '%s\n' "$HOME/.codex" ;;
  esac
}

# Absolute, `~` expanded, no trailing slash. The directory need not exist yet —
# installing is what creates it.
llmctx_account_expand_dir() {
  local dir="$1"
  # shellcheck disable=SC2088  # matching a LITERAL tilde is the point here
  case "$dir" in
    '~') dir="$HOME" ;;
    '~/'*) dir="$HOME/${dir#'~/'}" ;;
  esac
  while [[ "$dir" == */ && "$dir" != / ]]; do dir="${dir%/}"; done
  printf '%s\n' "$dir"
}

llmctx_account_validate_name() {
  local name="$1" provider="${2:-claude}" default_dir
  default_dir="$(llmctx_account_default_dir "$provider")" || return 1
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
    echo "error: account name '$name' must be lowercase letters, digits and hyphens" >&2
    return 1
  }
  [[ "$name" != "$LLMCTX_ACCOUNT_DEFAULT_NAME" ]] || {
    echo "error: '$LLMCTX_ACCOUNT_DEFAULT_NAME' is reserved for $default_dir" >&2
    return 1
  }
}

# Prints "<name>\t<dir>", `default` first. A malformed or colliding entry is a
# hard error rather than a skipped line: silently dropping one would install
# into fewer directories than asked for and still exit 0, which is the exact
# shape of the bug that made accounts necessary.
llmctx_accounts() {
  local provider="${1:-claude}" key entry name dir seen_names seen_dirs default_dir
  key="$(llmctx_account_key "$provider")" || return 1
  default_dir="$(llmctx_account_default_dir "$provider")" || return 1
  printf '%s\t%s\n' "$LLMCTX_ACCOUNT_DEFAULT_NAME" "$default_dir"
  seen_names=" $LLMCTX_ACCOUNT_DEFAULT_NAME "
  seen_dirs="	$default_dir	"

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    [[ "$entry" == *=* ]] || {
      echo "error: $key entry '$entry' is not <name>=<dir>" >&2
      return 1
    }
    name="${entry%%=*}"
    dir="$(llmctx_account_expand_dir "${entry#*=}")"
    llmctx_account_validate_name "$name" "$provider" || return 1
    [[ "$dir" == /* ]] || {
      echo "error: account '$name' directory '$dir' is not absolute" >&2
      return 1
    }
    case "$seen_names" in
      *" $name "*)
        echo "error: account '$name' is registered more than once" >&2
        return 1
        ;;
    esac
    # Two names for one directory would install twice and prune each other's
    # work on the second pass.
    case "$seen_dirs" in
      *"	$dir	"*)
        echo "error: '$dir' is already registered under another account" >&2
        return 1
        ;;
    esac
    seen_names="$seen_names$name "
    seen_dirs="$seen_dirs$dir	"
    printf '%s\t%s\n' "$name" "$dir"
  done < <(git config --global --get-all "$key" 2>/dev/null || true)
}

# The single account named, or every account when no name is given.
llmctx_accounts_selected() {
  local want="${1:-}" provider="${2:-claude}" all line
  all="$(llmctx_accounts "$provider")" || return 1
  [[ -n "$want" ]] || {
    printf '%s\n' "$all"
    return 0
  }
  while IFS= read -r line; do
    [[ "${line%%	*}" == "$want" ]] || continue
    printf '%s\n' "$line"
    return 0
  done <<<"$all"
  echo "error: unknown account '$want'" >&2
  echo "known: $(printf '%s\n' "$all" | cut -f1 | tr '\n' ' ')" >&2
  return 1
}

# A hook command path for an account, written $HOME-relative when it sits under
# $HOME so the generated settings stay portable between machines — Claude Code
# expands $HOME itself.
llmctx_account_home_path() {
  local dir="$1"
  case "$dir" in
    "$HOME") printf '%s\n' '$HOME' ;;
    "$HOME"/*) printf '$HOME/%s\n' "${dir#"$HOME"/}" ;;
    *) printf '%s\n' "$dir" ;;
  esac
}
