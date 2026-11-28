#!/usr/bin/env bash
set -euo pipefail

# Renaming a Claude hook file. The settings merge keeps any local entry naming a
# script this repository does not ship, which is right for a hand-written hook
# and wrong for our own previous name: after a rename the old entry would stay
# registered beside the new one, in every account. bin/claude-hooks/retired.conf
# lists the names that used to be ours. This takes an account as the previous
# release left it through the upgrade and checks that the old entry goes, the old
# PATH still reaches its successor for a session that started before the upgrade,
# nothing foreign is lost, and --check tells the two states apart.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
RETIRED="$SRC/bin/claude-hooks/retired.conf"

# Installs into throwaway homes; see tests/build-adapters-test.sh.
export LLMCTX_ALLOW_WORKTREE_INSTALL=1
unset CLAUDE_CONFIG_DIR

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-hook-rename.XXXXXX")"
tmp="$(cd "$tmp" && pwd)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "hook-rename test failed: $*" >&2
  exit 1
}

[[ -f "$RETIRED" ]] || fail "missing $RETIRED"
pairs="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$RETIRED" || true)"
if [[ -z "$pairs" ]]; then
  echo "hook-rename tests: no retired hooks, nothing to prove"
  exit 0
fi

# --- the list itself --------------------------------------------------------
# A retired name still shipped would be installed and shimmed over in one run; a
# successor that is missing or unregistered would turn its shim into a dead end.
while IFS='|' read -r old new; do
  [[ -n "$old" && -n "$new" ]] || fail "malformed line in retired.conf: $old|$new"
  [[ ! -e "$SRC/bin/claude-hooks/$old" ]] || fail "$old is retired and still shipped"
  [[ -f "$SRC/bin/claude-hooks/$new" ]] || fail "$old was retired in favour of $new, which is not shipped"
  jq -e --arg n "/$new" \
    '[.hooks[][]?.hooks[]?.command | select(endswith($n))] | length == 1' \
    "$SRC/claude/settings.json" >/dev/null ||
    fail "$new is not registered exactly once in claude/settings.json"
done <<<"$pairs"

first_old="${pairs%%|*}"

# --- reading the list --------------------------------------------------------
# A line the reader drops is a rename the installer never hears about, and the
# old registration then stays beside its successor. A final line with no newline
# is one way to lose a line: `read` fills its variables and still reports
# failure. A line with no successor must go the other way and be dropped, since
# its shim would exec the hooks directory itself.
# shellcheck source=bin/lib/accounts.sh
source "$SRC/bin/lib/accounts.sh"
printf '# comment\n\none.sh|uno.sh\nno-successor.sh\ntwo.sh|dos.sh' >"$tmp/list.conf"
got="$(llmctx_retired_hooks "$tmp/list.conf")"
[[ "$got" == $'one.sh|uno.sh\ntwo.sh|dos.sh' ]] ||
  fail "the list reader returned $(printf '%q' "$got")"

build() { # <home> [args...]
  local home="$1"
  shift
  HOME="$home" GIT_CONFIG_GLOBAL="$home/.gitconfig" "$SRC/bin/build-adapters.sh" "$@"
}
commands() { # <home> -> every registered hook command that is a plain string
  jq -r '[.hooks[][]?.hooks[]?.command | select(type == "string")][]' "$1/.claude/settings.json"
}
registered() { # <home> <basename> -> how many times it is registered
  commands "$1" | grep -c "/hooks/$2\$" || true
}

# An account as the previous release left it: this repository's settings with
# each successor spelled by its old name, the old scripts on disk, and four
# things that are nobody's business but the account owner's.
previous_account() { # <home>
  local home="$1" json old new
  mkdir -p "$home/.claude/hooks"
  : >"$home/.gitconfig"
  # shellcheck disable=SC2016  # a literal $HOME is what a rendered settings file holds
  json="$(sed 's|{{CLAUDE_CONFIG_DIR}}|$HOME/.claude|g' "$SRC/claude/settings.json")"
  while IFS='|' read -r old new; do
    json="$(sed "s|/hooks/$new\"|/hooks/$old\"|" <<<"$json")"
    printf '#!/usr/bin/env bash\necho previous-release\n' >"$home/.claude/hooks/$old"
    chmod +x "$home/.claude/hooks/$old"
  done <<<"$pairs"
  # shellcheck disable=SC2016
  jq --arg old "\$HOME/.claude/hooks/$first_old" '
    .theme = "dark"
    | .hooks.PreToolUse += [
        {matcher: "Bash", hooks: [{type: "command", command: "$HOME/.claude/hooks/local-guard.sh"}]},
        {matcher: "Write", hooks: [
          {type: "command", command: "$HOME/.claude/hooks/shared-guard.sh"},
          {type: "command", command: $old}]},
        {matcher: "Edit", hooks: [{type: "command", command: ["$HOME/.claude/hooks/array-guard.sh", "--strict"]}]}
      ]' <<<"$json" >"$home/.claude/settings.json"
}

# --- the upgrade -------------------------------------------------------------
home="$tmp/upgrade"
previous_account "$home"
build "$home" >/dev/null 2>"$tmp/err" || fail "the upgrade build failed: $(cat "$tmp/err")"

while IFS='|' read -r old new; do
  [[ "$(registered "$home" "$old")" == 0 ]] || fail "retired $old is still registered after the upgrade"
  [[ "$(registered "$home" "$new")" == 1 ]] || fail "$new is registered $(registered "$home" "$new") times, expected once"
  [[ -x "$home/.claude/hooks/$new" ]] || fail "$new was not installed"
done <<<"$pairs"

commands "$home" | grep -q '/hooks/local-guard.sh$' || fail "a foreign hook entry was lost"
commands "$home" | grep -q '/hooks/shared-guard.sh$' ||
  fail "a foreign hook sharing a group with a retired one was lost with it"
jq -e '[.hooks.PreToolUse[].hooks[].command | select(type == "array")] | length == 1' \
  "$home/.claude/settings.json" >/dev/null || fail "a foreign hook with an array command was lost"
jq -e '.theme == "dark"' "$home/.claude/settings.json" >/dev/null || fail "an undeclared local key was lost"

# A rebuild changes nothing more.
before="$(commands "$home")"
build "$home" >/dev/null 2>&1
[[ "$(commands "$home")" == "$before" ]] || fail "a second build changed the registered hooks"

# --- the old path, for a session that started before the upgrade -------------
# A hook command that cannot start does not block, so deleting the old file
# would switch the check off for every session still holding its path. The old
# path must reach the successor, with stdin intact. Proven with a probe standing
# in for the successor, so this holds for a gate and a notice alike.
while IFS='|' read -r old new; do
  [[ "$(sed -n '2p' "$home/.claude/hooks/$old")" == '# llmctx-retired-hook' ]] ||
    fail "$old was left as the previous release's script instead of a shim"
  [[ -x "$home/.claude/hooks/$old" ]] || fail "the shim at $old is not executable"
  printf '#!/usr/bin/env bash\ncat\necho " reached %s"\n' "$new" >"$home/.claude/hooks/$new"
  got="$(printf 'payload' | "$home/.claude/hooks/$old")"
  [[ "$got" == "payload reached $new" ]] || fail "the shim at $old did not hand stdin to $new: $got"
done <<<"$pairs"
build "$home" >/dev/null 2>&1 # put the real successors back

# --- --check tells the states apart -----------------------------------------
build "$home" --check >/dev/null 2>&1 || fail "--check reported drift on a freshly upgraded account"

printf '#!/usr/bin/env bash\necho previous-release\n' >"$home/.claude/hooks/$first_old"
build "$home" --check >"$tmp/check.out" 2>&1 && fail "--check passed a retired hook that is not the shim"
grep -q "drift: .*/hooks/$first_old" "$tmp/check.out" || fail "--check did not name the retired file: $(cat "$tmp/check.out")"
build "$home" >/dev/null 2>&1

# shellcheck disable=SC2016
jq --arg old "\$HOME/.claude/hooks/$first_old" \
  '.hooks.PreToolUse += [{matcher: "Bash", hooks: [{type: "command", command: $old}]}]' \
  "$home/.claude/settings.json" >"$tmp/settings.json"
cp "$tmp/settings.json" "$home/.claude/settings.json"
build "$home" --check >"$tmp/check.out" 2>&1 && fail "--check passed a settings file that registers a retired hook"
grep -q 'drift: .*settings.json' "$tmp/check.out" || fail "--check did not name the settings file: $(cat "$tmp/check.out")"
build "$home" >/dev/null 2>&1
build "$home" --check >/dev/null 2>&1 || fail "a build did not clear the drift it was pointed at"

# --- doctor does not call the shim somebody else's hook ---------------------
HOME="$home" GIT_CONFIG_GLOBAL="$home/.gitconfig" "$SRC/bin/doctor.sh" --json >"$tmp/doctor.json" 2>/dev/null || true
detail="$(jq -r '[.checks[] | select(.id == "claude-hooks") | .detail] | join(" ")' "$tmp/doctor.json")"
[[ -n "$detail" ]] || fail "doctor reported no claude-hooks check"
while IFS='|' read -r old new; do
  case " $detail " in
    *" $old "* | *" $old;"*) fail "doctor reported the shim at $old as an unmanaged hook: $detail" ;;
  esac
done <<<"$pairs"

# --- an account that never had the old file gets no shim --------------------
fresh="$tmp/fresh"
mkdir -p "$fresh/.claude"
: >"$fresh/.gitconfig"
build "$fresh" >/dev/null 2>&1 || fail "the fresh-account build failed"
while IFS='|' read -r old new; do
  [[ ! -e "$fresh/.claude/hooks/$old" ]] || fail "a fresh account was given a shim at $old"
done <<<"$pairs"

# --- a name the owner declared as theirs is left alone -----------------------
# llmctx.accountHook says "this script is mine". If it happens to carry a name
# this repository retired, neither the file nor its registration is ours to touch.
kept="$tmp/kept"
previous_account "$kept"
git config --file "$kept/.gitconfig" --add llmctx.accountHook "$first_old"
build "$kept" >/dev/null 2>&1 || fail "the declared-hook build failed"
grep -q 'previous-release' "$kept/.claude/hooks/$first_old" || fail "a declared hook was replaced by a shim"
[[ "$(registered "$kept" "$first_old")" -ge 1 ]] || fail "a declared hook's registration was dropped"

echo "hook-rename tests: passed"
