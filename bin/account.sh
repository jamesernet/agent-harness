#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/accounts.sh
source "$SCRIPT_DIR/lib/accounts.sh"

usage() {
  cat <<'USAGE'
usage:
  llmctx account list [--provider claude|codex] [--json]
  llmctx account add [--provider claude|codex] <name> <dir>
  llmctx account remove [--provider claude|codex] <name>

A provider account is a Claude or Codex config directory — a separate login,
keyed by CLAUDE_CONFIG_DIR or CODEX_HOME. Registering one makes `llmctx install`
and `llmctx doctor` cover it. Claude is the default provider so existing
commands keep their meaning. $HOME/.claude and $HOME/.codex are always covered
as `default` for their provider.

Route a repository to an account with direnv, in the directory above it:
  echo 'export CLAUDE_CONFIG_DIR="$HOME/.claude-acme"' > .envrc && direnv allow
A repository with its own .envrc needs `source_up_if_exists` as its first line,
or it shadows the parent silently and the routing does not apply.
USAGE
}

cmd_list() {
  local json=0 provider=claude name dir accounts
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --json) json=1 ;;
      --provider)
        provider="${2:-}"
        shift
        ;;
      --provider=*) provider="${1#--provider=}" ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
    shift
  done
  llmctx_account_validate_provider "$provider"
  # Resolved into a variable rather than piped: a malformed registry makes
  # llmctx_accounts fail AFTER printing the entries it already parsed, and a
  # process substitution would discard that failure and print a short list as
  # though it were the whole thing.
  accounts="$(llmctx_accounts "$provider")" || exit 1
  while IFS=$'\t' read -r name dir; do
    [[ -n "$name" ]] || continue
    if [[ "$json" -eq 1 ]]; then
      jq -cn --arg provider "$provider" --arg name "$name" --arg dir "$dir" \
        --argjson exists "$([[ -d "$dir" ]] && echo true || echo false)" \
        '{provider:$provider,name:$name,dir:$dir,exists:$exists}'
    else
      printf '%-12s %s%s\n' "$name" "$dir" "$([[ -d "$dir" ]] || echo '   (not created yet)')"
    fi
  done <<<"$accounts"
}

cmd_add() {
  local provider=claude name="" dir="" key existing existing_name existing_dir
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --provider)
        provider="${2:-}"
        shift
        ;;
      --provider=*) provider="${1#--provider=}" ;;
      *)
        if [[ -z "$name" ]]; then name="$1"; elif [[ -z "$dir" ]]; then dir="$1"; else
          usage >&2
          exit 2
        fi
        ;;
    esac
    shift
  done
  [[ -n "$name" && -n "$dir" ]] || {
    usage >&2
    exit 2
  }
  llmctx_account_validate_provider "$provider"
  key="$(llmctx_account_key "$provider")"
  llmctx_account_validate_name "$name" "$provider"
  dir="$(llmctx_account_expand_dir "$dir")"
  if llmctx_path_unexpanded_tilde "$dir"; then
    echo "error: '$dir': $(llmctx_path_tilde_reason)" >&2
    exit 1
  fi
  [[ "$dir" == /* ]] || {
    echo "error: '$dir' is not an absolute directory" >&2
    exit 1
  }
  # Resolve the whole registry first so a collision is refused before anything
  # is written, rather than leaving a registry that no command can read.
  existing="$(llmctx_accounts "$provider")"
  while IFS=$'\t' read -r existing_name existing_dir; do
    [[ "$existing_name" != "$name" ]] || {
      echo "error: account '$name' already registered as $existing_dir" >&2
      exit 1
    }
    [[ "$existing_dir" != "$dir" ]] || {
      echo "error: $dir is already registered as '$existing_name'" >&2
      exit 1
    }
  done <<<"$existing"

  git config --global --add "$key" "$name=$dir"
  llmctx_accounts "$provider" >/dev/null || {
    git config --global --unset "$key" "^$name="
    echo "error: registry was left unchanged" >&2
    exit 1
  }
  echo "registered: $provider/$name -> $dir"
  echo "run 'llmctx install' to populate it."
}

cmd_remove() {
  local provider=claude name="" key
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --provider)
        provider="${2:-}"
        shift
        ;;
      --provider=*) provider="${1#--provider=}" ;;
      *) [[ -z "$name" ]] && name="$1" || {
        usage >&2
        exit 2
      } ;;
    esac
    shift
  done
  [[ -n "$name" ]] || {
    usage >&2
    exit 2
  }
  llmctx_account_validate_provider "$provider"
  key="$(llmctx_account_key "$provider")"
  [[ "$name" != "$LLMCTX_ACCOUNT_DEFAULT_NAME" ]] || {
    echo "error: '$LLMCTX_ACCOUNT_DEFAULT_NAME' cannot be unregistered" >&2
    exit 1
  }
  git config --global --get-regexp "^${key}$" "^$name=" >/dev/null 2>&1 || {
    echo "error: no account named '$name'" >&2
    exit 1
  }
  git config --global --unset "$key" "^$name="
  # Unregistering stops managing the directory; it does not delete a login.
  # Removing someone's credential store as a side effect of a config change is
  # not a trade this tool gets to make on their behalf.
  echo "unregistered: $provider/$name"
  echo "its config directory and login are untouched; delete them yourself if you meant to."
}

case "${1:-}" in
  list)
    shift
    cmd_list "$@"
    ;;
  add)
    shift
    cmd_add "$@"
    ;;
  remove)
    shift
    cmd_remove "$@"
    ;;
  -h | --help | help) usage ;;
  *)
    usage >&2
    exit 2
    ;;
esac
