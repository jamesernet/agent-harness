# shellcheck shell=bash
# Account routes: which Claude account a path belongs to, and which is active.
#
# `llmctx.accountRoute name=path` entries in global git config say which tree
# belongs to which account, and `llmctx.claudeAccount name=dir` is the registry
# the names resolve against. account-guard.sh answered both questions inline;
# the SessionStart tripwire needs the same answers for the session cwd, and two
# hooks answering one question separately is how target.sh's two callers drifted
# (#67). One implementation, here, installed beside the hooks as
# llmctx-routes.sh next to llmctx-target.sh, whose path helpers it uses.
#
# Bash 3.2 (macOS) — no associative arrays, no `declare -g`.
#
# INTERFACE
#
#   llmctx_routes_list                 raw name=path entries, one per line; empty when none
#   llmctx_routes_active_dir           ${CLAUDE_CONFIG_DIR:-$HOME/.claude}, expanded and canonical
#   llmctx_routes_active_account       the registered name of that directory; `default` for
#                                      $HOME/.claude, registered or not; nothing if unregistered
#   llmctx_routes_match <path>         "name<TAB>path" of the longest route containing the
#                                      canonical path; nothing when no route matches
#   llmctx_routes_account_dir <name>   the registered config directory for an account name,
#                                      $HOME/.claude for `default`; nothing if unregistered
#
# Every function returns 0 and prints nothing when it cannot tell. "Cannot
# tell" is a first-class answer: both callers say nothing rather than guess, so
# a wrong route or an unregistered directory can never produce a wrong denial.

llmctx_routes_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F llmctx_target_canonical >/dev/null 2>&1; then
  if [[ -f "$llmctx_routes_lib_dir/llmctx-target.sh" ]]; then
    # shellcheck source=target.sh
    source "$llmctx_routes_lib_dir/llmctx-target.sh"
  else
    # shellcheck source=target.sh
    source "$llmctx_routes_lib_dir/target.sh"
  fi
fi

llmctx_routes_list() {
  git config --global --get-all llmctx.accountRoute 2>/dev/null || true
}

llmctx_routes_active_dir() {
  llmctx_target_canonical "$(llmctx_target_expand_home "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")"
}

llmctx_routes_active_account() {
  local active_dir entry name dir
  active_dir="$(llmctx_routes_active_dir)"
  if [[ "$active_dir" == "$(llmctx_target_canonical "$HOME/.claude")" ]]; then
    printf '%s\n' default
    return 0
  fi
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    name="${entry%%=*}"
    dir="$(llmctx_target_canonical "$(llmctx_target_expand_home "${entry#*=}")")"
    if [[ "$dir" == "$active_dir" ]]; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(git config --global --get-all llmctx.claudeAccount 2>/dev/null || true)
  return 0
}

# Longest matching route wins, so a nested tree can belong to a different
# account than its parent. A relative route never matches; doctor reports it.
llmctx_routes_match() { # <canonical absolute path>
  local target="$1" entry name path best_name="" best_path=""
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    name="${entry%%=*}"
    path="$(llmctx_target_expand_home "${entry#*=}")"
    [[ "$path" == /* ]] || continue
    path="$(llmctx_target_canonical "$path")"
    [[ -n "$path" ]] || continue
    case "$target" in
      "$path" | "$path"/*)
        if [[ "${#path}" -gt "${#best_path}" ]]; then
          best_name="$name"
          best_path="$path"
        fi
        ;;
    esac
  done < <(llmctx_routes_list)
  if [[ -n "$best_name" ]]; then
    printf '%s\t%s\n' "$best_name" "$best_path"
  fi
  return 0
}

llmctx_routes_account_dir() { # <account name>
  local want="$1" entry
  if [[ "$want" == default ]]; then
    printf '%s\n' "$HOME/.claude"
    return 0
  fi
  while IFS= read -r entry; do
    [[ "${entry%%=*}" == "$want" ]] || continue
    llmctx_target_expand_home "${entry#*=}"
    return 0
  done < <(git config --global --get-all llmctx.claudeAccount 2>/dev/null || true)
  return 0
}
