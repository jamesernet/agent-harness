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
#   llmctx_routes_load                 read both git config keys, once per process
#   llmctx_routes_list                 the raw name=path route entries, one per line
#   llmctx_routes_active_dir           ${CLAUDE_CONFIG_DIR:-$HOME/.claude}, expanded and canonical
#   llmctx_routes_active_account       the registered name of that directory; `default` for
#                                      $HOME/.claude, registered or not; nothing if unregistered
#   llmctx_routes_match <path>         "name<TAB>path" of the longest route containing the
#                                      canonical path; nothing when no route matches
#   llmctx_routes_account_dir <name>   the registered config directory for an account name,
#                                      $HOME/.claude for `default`; nothing if unregistered
#   llmctx_routes_judge <path>         everything a hook decides before it may speak, in one
#                                      call: "route<TAB>route path<TAB>expected dir<TAB>active
#                                      name<TAB>active dir" when the path is routed to an account
#                                      other than the active one and both are registered;
#                                      nothing otherwise. The path is expanded and canonicalised
#                                      here, so a caller cannot miss a route by handing over
#                                      /var where the route resolved to /private/var
#   llmctx_routes_fix_text <route path> <active name> <active dir>
#                                      the remediation both hooks print, word for word
#
# Every function returns 0 and prints nothing when it cannot tell. "Cannot
# tell" is a first-class answer: both callers say nothing rather than guess, so
# a wrong route or an unregistered directory can never produce a wrong denial.
# The silent cases of `judge`, which are the silent cases of both hooks: no
# routes; the sentinel file in the active account's directory; an unregistered
# CLAUDE_CONFIG_DIR; no route containing the path; the path routed to the
# active account itself; a route naming an unregistered account, which is
# doctor's finding, since a denial pointing at a directory that does not exist
# would send the person the wrong way.
#
# ONE READ. account-guard.sh runs on every Edit, Write and Bash call, and the
# inline version read each key once. The library keeps that: `load` reads both
# keys into two variables and every other function reads those, so a hook spawns
# git twice however many questions it asks. A `$(...)` caller inherits the loaded
# variables, so the cache survives command substitution; only a function run
# before `load` loads for itself.

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

LLMCTX_ROUTES=""
LLMCTX_ROUTE_ACCOUNTS=""
LLMCTX_ROUTES_LOADED=0

llmctx_routes_load() {
  LLMCTX_ROUTES="$(git config --global --get-all llmctx.accountRoute 2>/dev/null || true)"
  LLMCTX_ROUTE_ACCOUNTS="$(git config --global --get-all llmctx.claudeAccount 2>/dev/null || true)"
  LLMCTX_ROUTES_LOADED=1
}

llmctx_routes_loaded() {
  [[ "$LLMCTX_ROUTES_LOADED" -eq 1 ]] || llmctx_routes_load
}

llmctx_routes_list() {
  llmctx_routes_loaded
  [[ -z "$LLMCTX_ROUTES" ]] || printf '%s\n' "$LLMCTX_ROUTES"
}

llmctx_routes_active_dir() {
  llmctx_target_canonical "$(llmctx_target_expand_home "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")"
}

llmctx_routes_active_account() {
  local active_dir entry name dir
  llmctx_routes_loaded
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
  done <<<"$LLMCTX_ROUTE_ACCOUNTS"
  return 0
}

# Longest matching route wins, so a nested tree can belong to a different
# account than its parent. A relative route never matches; doctor reports it.
llmctx_routes_match() { # <canonical absolute path>
  local target="$1" entry name path best_name="" best_path=""
  llmctx_routes_loaded
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
  done <<<"$LLMCTX_ROUTES"
  if [[ -n "$best_name" ]]; then
    printf '%s\t%s\n' "$best_name" "$best_path"
  fi
  return 0
}

llmctx_routes_account_dir() { # <account name>
  local want="$1" entry
  llmctx_routes_loaded
  if [[ "$want" == default ]]; then
    printf '%s\n' "$HOME/.claude"
    return 0
  fi
  while IFS= read -r entry; do
    [[ "${entry%%=*}" == "$want" ]] || continue
    llmctx_target_expand_home "${entry#*=}"
    return 0
  done <<<"$LLMCTX_ROUTE_ACCOUNTS"
  return 0
}

llmctx_routes_judge() { # <absolute path>
  local target active_dir active_name match route_name route_path expected_dir
  llmctx_routes_loaded
  [[ -n "$LLMCTX_ROUTES" ]] || return 0
  target="$(llmctx_target_canonical "$(llmctx_target_expand_home "$1")")"
  [[ "$target" == /* ]] || return 0
  active_dir="$(llmctx_routes_active_dir)"
  [[ ! -e "$active_dir/.allow-cross-account" ]] || return 0
  active_name="$(llmctx_routes_active_account)"
  [[ -n "$active_name" ]] || return 0
  match="$(llmctx_routes_match "$target")"
  [[ -n "$match" ]] || return 0
  route_name="${match%%	*}"
  route_path="${match#*	}"
  [[ "$route_name" != "$active_name" ]] || return 0
  expected_dir="$(llmctx_routes_account_dir "$route_name")"
  [[ -n "$expected_dir" ]] || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$route_name" "$route_path" "$expected_dir" "$active_name" "$active_dir"
}

# One story whichever hook spoke first: the tripwire says it at session start,
# the guard at the first write, and the person should not read two versions.
llmctx_routes_fix_text() { # <route path> <active name> <active dir>
  local route_path="$1" active_name="$2" active_dir="$3"
  cat <<EOF
The likely cause is a shell that never loaded direnv. From a terminal OUTSIDE this session:
  cd "$route_path" && direnv allow .
  # then start a new session there: claude    and confirm with /status

If a repo under that path has its own .envrc, it needs 'source_up_if_exists' as its
first line, or it shadows the parent entirely and this keeps firing.

To work here on the "$active_name" account deliberately, suspend the guard:
  touch "$active_dir/.allow-cross-account"    # then rm it when done
EOF
}
