#!/usr/bin/env bash
set -euo pipefail

# bin/claude-hooks/irreversible-policy.sh — the second tenant on the policy
# ladder. Driven through its real stdin contract, like the branch-policy suite.
#
# Half of this file is false-positive cases. A guard that is wrong on ordinary
# work gets switched off, and then it protects nothing — so "this must NOT
# fire" is as much the contract as "this must".

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$SRC/bin/claude-hooks/irreversible-policy.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-irrev-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd)"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp/home"
export GIT_CONFIG_GLOBAL="$tmp/home/.gitconfig"
mkdir -p "$HOME"
: >"$GIT_CONFIG_GLOBAL"

fail() {
  echo "irreversible-policy test failed: $*" >&2
  exit 1
}

repo="$tmp/repo"
mkdir -p "$repo/sub" "$tmp/outside"
git init --quiet "$repo"
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name T

outside_repo="$tmp/plain" # a directory that is NOT a git repository
mkdir -p "$outside_repo"

payload() { # <cwd> <command>
  jq -nc --arg c "$2" --arg d "$1" \
    '{tool_name: "Bash", cwd: $d, tool_input: {command: $c}}'
}

# Empty output IS the allow case — the hook prints nothing when it has no
# opinion — so emptiness is checked before jq, which would otherwise print
# nothing for nothing and never reach its own default.
decide() { # <cwd> <command> -> allow|ask|deny
  local out
  out="$(payload "$1" "$2" | bash "$HOOK" 2>/dev/null || true)"
  if [[ -z "${out//[[:space:]]/}" ]]; then
    echo allow
    return
  fi
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo allow
}

want() { # <expected> <description> <cwd> <command>
  local expected="$1" desc="$2" got
  got="$(decide "$3" "$4")"
  [[ "$got" == "$expected" ]] ||
    fail "$desc: expected $expected, got $got  [cmd: $4]"
}

# The literal is split so this test file can itself be edited by an agent
# without the guard under test matching its own source.
PF="git"" push --force"
RH="git"" reset --hard"

# ============================ MUST FIRE ============================
# Default policy is `ask`, from the built-in, with nothing configured.
want ask "force push" "$repo" "$PF origin main"
want ask "short -f force push" "$repo" "git"" push -f origin main"
want ask "force-with-lease" "$repo" "git"" push --force-with-lease origin main"
want ask "hard reset" "$repo" "$RH HEAD~3"
want ask "filter-branch" "$repo" "git"" filter-branch --tree-filter x HEAD"
want ask "force branch delete" "$repo" "git"" branch -D feature/x"
want ask "remote branch delete" "$repo" "git"" push origin --delete feature/x"
want ask "colon refspec delete" "$repo" "git"" push origin :feature/x"
want ask "rm -rf outside repo" "$repo" "rm -rf $tmp/outside"
want ask "rm -rf \$HOME" "$repo" 'rm -rf "$HOME"'
want ask "rm -rf / " "$repo" "rm -rf /"
want ask "rm -rf ~" "$repo" "rm -rf ~"

# Behind a prefix, and as a later statement — the shared statement splitter.
want ask "force push after &&" "$repo" "git"" fetch && $PF origin main"
want ask "force push after ;" "$repo" "echo hi; $PF origin main"

# ======================= MUST NOT FIRE =======================
# Ordinary work. Each of these firing is what would get the hook removed.
want allow "plain push" "$repo" "git"" push origin feature/x"
want allow "plain commit" "$repo" "git"" commit -m x"
want allow "soft reset" "$repo" "git"" reset --soft HEAD~1"
want allow "plain reset" "$repo" "git"" reset HEAD~1"
want allow "safe branch delete" "$repo" "git"" branch -d feature/x"
want allow "branch list" "$repo" "git"" branch -a"
want allow "rebase is not matched" "$repo" "git"" rebase main"
want allow "amend is not matched" "$repo" "git"" commit --amend --no-edit"
want allow "rm -rf inside repo" "$repo" "rm -rf $repo/node_modules"
want allow "rm -rf relative inside" "$repo" "rm -rf node_modules"
want allow "rm -rf sub inside" "$repo" "rm -rf sub/dist"
want allow "rm single file" "$repo" "rm $tmp/outside/f"
want allow "non-recursive rm -f" "$repo" "rm -f $tmp/outside/f"

# The flag must be a word, not a substring of an argument.
want allow "branch named -force" "$repo" "git"" push origin feature/force-rework"
want allow "message mentioning it" "$repo" "git"" commit -m 'no --force here'"

# The verb must be git's, not a quoted mention inside another command.
want allow "echoing the command" "$repo" "echo '$PF origin main'"
want allow "grepping for it" "$repo" "grep -r 'reset --hard' ."

# A force push inside a command substitution still pushes. The first version
# allowed this on the grounds that a subshell isolates the outer command — true
# of its working directory and variables, false of its side effects — and
# pinned the bypass as a must-allow case. Retired deliberately, not quietly.
want ask "force push in \$( )" "$repo" "echo \"\$($PF origin main)\""
want ask "force push in backticks" "$repo" "echo \`$PF origin main\`"

# Prefixes a shell allows in front of the verb (review of PR #77, finding 1).
want ask "sudo rm -rf /" "$repo" "sudo rm -rf /"
want ask "/bin/rm -rf /" "$repo" "/bin/rm -rf /"
want ask "sudo force push" "$repo" "sudo $PF origin main"
want ask "env prefix" "$repo" "env GIT_TRACE=1 $PF origin main"
want ask "assignment prefix" "$repo" "GIT_TRACE=1 $PF origin main"
want ask "command prefix" "$repo" "command rm -rf $tmp/outside"
want ask "/bin/rm outside repo" "$repo" "/bin/rm -rf $tmp/outside"
want allow "/bin/rm inside repo" "$repo" "/bin/rm -rf $repo/node_modules"

# Flag spellings git accepts (finding 3).
want ask "clustered -fu" "$repo" "git"" push -fu origin main"
want ask "clustered -uf" "$repo" "git"" push -uf origin main"
want ask "+refspec" "$repo" "git"" push origin +main"
want ask "clustered -fd" "$repo" "git"" push -fd origin feature/x"
want ask "--force --delete on branch" "$repo" "git"" branch --force --delete feature/x"
want ask "--delete --force on branch" "$repo" "git"" branch --delete --force feature/x"
want ask "-d -f on branch" "$repo" "git"" branch -d -f feature/x"

# A remote-tracking ref is undone by `git fetch` (finding 7).
want allow "-rd is recoverable" "$repo" "git"" branch -rd origin/stale"
want allow "-r -d is recoverable" "$repo" "git"" branch -r -d origin/stale"
want allow "-rD is recoverable" "$repo" "git"" branch -rD origin/stale"

# Trailing slash spellings of root and home (finding 5).
want ask "rm -rf ~/" "$repo" "rm -rf ~/"
want ask "rm -rf //" "$repo" "rm -rf //"
want ask "rm -rf /." "$repo" "rm -rf /."
want ask "rm -rf /.. " "$repo" "rm -rf /.."
want ask "rm -rf \$HOME/" "$repo" 'rm -rf "$HOME/"'
want ask "rm -rf ~/ with no repo" "$outside_repo" "rm -rf ~/"

# Outside a repository only the catastrophic targets are judged — the stated
# limit in the hook's header.
want allow "rm -r in a plain dir" "$outside_repo" "rm -rf $tmp/outside"
want ask "rm -rf / with no repo" "$outside_repo" "rm -rf /"

# Not Bash at all. An Edit or a Write cannot force-push, so the hook has no
# opinion and prints nothing.
got="$(jq -nc --arg d "$repo" '{tool_name: "Edit", cwd: $d, tool_input: {file_path: "/x"}}' |
  bash "$HOOK" 2>/dev/null || true)"
[[ -z "${got//[[:space:]]/}" ]] || fail "an Edit must not be judged, got: $got"

# ======================= THE LADDER =======================
git config --global llmctx.irreversiblePolicy deny
want deny "global deny applies" "$repo" "$PF origin main"
git config --global llmctx.irreversiblePolicy off
want allow "global off applies" "$repo" "$PF origin main"

# remind is honestly degraded to ask: reminding once and then allowing every
# destructive command that follows protects nothing.
git config --global llmctx.irreversiblePolicy remind
want ask "remind behaves as ask" "$repo" "$PF origin main"
# ...and unlike branch-policy's remind, it fires EVERY time rather than once.
want ask "remind fires again" "$repo" "$PF origin main"
git config --global --unset llmctx.irreversiblePolicy

# Repo-local git config outranks global.
git config --global llmctx.irreversiblePolicy deny
git -C "$repo" config llmctx.irreversiblePolicy ask
want ask "repo-local outranks global" "$repo" "$PF origin main"
git -C "$repo" config --unset llmctx.irreversiblePolicy
git config --global --unset llmctx.irreversiblePolicy

# Committed policy is read.
cat >"$repo/.llmctx.json" <<'JSON'
{"schemaVersion": 1, "profile": "personal", "irreversiblePolicy": "deny"}
JSON
want deny "committed policy is read" "$repo" "$PF origin main"

# An INVALID irreversiblePolicy fails OPEN, like the other two hooks.
cat >"$repo/.llmctx.json" <<'JSON'
{"schemaVersion": 1, "irreversiblePolicy": "sometimes"}
JSON
want allow "an invalid policy fails open" "$repo" "$PF origin main"

# ...but a typo in an UNRELATED key does not switch this gate off (finding 4).
# llmctx_policy_resolve validates every key and returns 1 on a bad
# branchPolicy; this hook resolves its own key on its own.
cat >"$repo/.llmctx.json" <<'JSON'
{"schemaVersion": 1, "branchPolicy": "stirct"}
JSON
want ask "a typo in branchPolicy does not disable this gate" "$repo" "$PF origin main"
cat >"$repo/.llmctx.json" <<'JSON'
{"schemaVersion": 1, "branchPolicy": "stirct", "irreversiblePolicy": "deny"}
JSON
want deny "a typo in branchPolicy does not hide an explicit deny" "$repo" "$PF origin main"
rm -f "$repo/.llmctx.json"

# The default is `ask` for BOTH profiles, deliberately unlike branchPolicy,
# which derives its default from the profile.
for prof in personal client; do
  printf '{"schemaVersion": 1, "profile": "%s"}\n' "$prof" >"$repo/.llmctx.json"
  want ask "default is ask under profile=$prof" "$repo" "$PF origin main"
done
rm -f "$repo/.llmctx.json"

# ======================= THE PAYLOAD =======================
out="$(payload "$repo" "$PF origin main" | bash "$HOOK")"
printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null ||
  fail "the hook event name is wrong"
reason="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
grep -q 'force push' <<<"$reason" || fail "the reason does not name the finding"
grep -q 'irreversiblePolicy = ask (source: built-in)' <<<"$reason" ||
  fail "the reason does not report the policy and its source: $reason"
grep -q "$repo" <<<"$reason" || fail "the reason does not name the repository"

# The hook never exits non-zero, whatever it decides — a guard that returns a
# failure wedges the tool call instead of answering it.
st=0
payload "$repo" "$PF origin main" | bash "$HOOK" >/dev/null || st=$?
[[ "$st" -eq 0 ]] || fail "the hook exited $st when denying"

# ...and anything unexpected allows rather than erroring.
for bad in 'not json at all' '' '{' '{"tool_name":"Bash"}' '{"tool_name":"Bash","tool_input":{}}'; do
  st=0
  out="$(printf '%s' "$bad" | bash "$HOOK" 2>/dev/null)" || st=$?
  [[ "$st" -eq 0 ]] || fail "the hook exited $st on payload: $bad"
  [[ -z "${out//[[:space:]]/}" ]] || fail "did not fail open on payload: $bad"
done

echo "irreversible policy tests: passed"
