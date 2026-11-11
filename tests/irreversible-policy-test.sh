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
# The hook treats paths under $TMPDIR as scratch, and this test's fixtures live
# under the real one -- so the hook is given a scratch root of its own, and the
# fixtures stay "outside".
scratch_root="$tmp/scratch-root"
mkdir -p "$scratch_root"
decide() { # <cwd> <command> -> allow|ask|deny
  local out
  out="$(payload "$1" "$2" | TMPDIR="$scratch_root" bash "$HOOK" 2>/dev/null || true)"
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

# The second review's bypasses: a prefix flag with a separate value, a shell
# keyword or brace in front of the verb, a quote glued to the path, another
# user's home, and --prune.
want ask "sudo -u root" "$repo" "sudo -u root rm -rf /"
want ask "sudo -n -u root force push" "$repo" "sudo -n -u root $PF origin main"
want ask "brace group" "$repo" "{ $PF origin main; }"
want ask "if/then" "$repo" "if true; then $PF origin main; fi"
want ask "for/do" "$repo" "for r in a; do $PF \$r main; done"
want ask "negated" "$repo" "! $PF origin main"
want ask "case arm" "$repo" "case x in a) $PF origin main;; esac"
want ask "quote before the slash" "$repo" 'rm -rf "$HOME"/'
want ask "quoted root" "$repo" "rm -rf '/'"
want ask "another user's home" "$repo" "rm -rf ~root" # a user that exists; ~someone is a literal directory
want ask "push --prune" "$repo" "git"" push --prune origin"
want allow "a keyword inside an argument" "$repo" "git"" commit -m 'then do it'"
# ${HOME} is expanded like $HOME, and the braces are not statement separators:
# $tmp/home/../repo is the test repository, so this resolves inside it.
want allow "braces inside a path" "$repo" 'rm -rf ${HOME}/../repo/node_modules'
want ask "braces, outside" "$repo" 'rm -rf ${HOME}/Documents'
# Handed to another interpreter: the header names this as the stated limit.
want allow "eval is not evaluated" "$repo" "eval '$PF origin main'"
want allow "bash -c is not evaluated" "$repo" "bash -c '$PF origin main'"

# The third review's bypasses.
want ask "nice prefix" "$repo" "nice -n 5 rm -rf /"
want ask "time prefix" "$repo" "time rm -rf /"
want ask "timeout prefix" "$repo" "timeout 30 rm -rf /"
want ask "doas prefix" "$repo" "doas $PF origin main"
want ask "escaped verb" "$repo" "\\$PF origin main"
want ask "escaped space in verb" "$repo" "git\\ push --force origin main"
want ask "quoted verb" "$repo" "\"git\" push --force origin main"
want ask "single-quoted verb" "$repo" "'git' push --force origin main"
want ask "push --mirror" "$repo" "git"" push --mirror origin"
want ask "branch -M" "$repo" "git"" branch -M main"
want ask "branch --force move" "$repo" "git"" branch --force main HEAD~5"
want ask "branch -f move" "$repo" "git"" branch -f main HEAD~5"
want ask "update-ref -d" "$repo" "git"" update-ref -d refs/heads/main"
want ask "reflog expire now" "$repo" "git"" reflog expire --expire=now --all"
want ask "gc prune now" "$repo" "git"" gc --prune=now"
want allow "branch -m rename" "$repo" "git"" branch -m old new"
want allow "plain gc" "$repo" "git"" gc"
want allow "plain reflog expire" "$repo" "git"" reflog expire"
want allow "update-ref set" "$repo" "git"" update-ref refs/heads/x HEAD"
# A target built from a variable or a substitution is not judged either way:
# the hook never evaluates shell, and the first version resolved the literal
# text against the repository and called "$(pwd)/../.." inside it.
want allow "variable target" "$repo" 'rm -rf "$BUILD_DIR"'
want allow "substitution target" "$repo" 'rm -rf "$(pwd)/../.."'
want allow "variable verb is a stated limit" "$repo" "g=git; \$g push --force origin main"
# A directory literally named ~something, inside the repository, is not a home.
mkdir -p "$repo/~literal-dir"
want allow "a literal ~ directory" "$repo" "rm -rf '~literal-dir'"
want allow "a literal ~ directory, unquoted path" "$repo" "rm -rf ~literal-dir-that-is-no-user"

# The fourth review: false positives on ordinary work, which is the class
# that gets a guard switched off.
git -C "$repo" -c user.email=t@example.com -c user.name=T commit -q --allow-empty -m root
git -C "$repo" worktree add -q "$tmp/sibling-wt" -b feature/sibling
mkdir -p "$tmp/sibling-wt/node_modules" "$HOME/.cache/pip" "$scratch_root/build"
want allow "a sibling worktree of the same repository" "$repo" "rm -rf $tmp/sibling-wt/node_modules"
want allow "a sibling worktree, relative" "$repo" "rm -rf ../sibling-wt/node_modules"
want allow "under TMPDIR" "$repo" "rm -rf $scratch_root/build"
want allow "under ~/.cache" "$repo" "rm -rf ~/.cache/pip"
want allow "under \$HOME/.cache" "$repo" 'rm -rf $HOME/.cache/pip'
want ask "a home subpath that is not scratch" "$repo" "rm -rf ~/Documents"
want ask "\$HOME/<subpath> is known by name" "$repo" 'rm -rf $HOME/Documents'
want ask "a scratch ROOT itself" "$repo" "rm -rf $scratch_root"
want allow "a heredoc body mentioning a force push" "$repo" "cat > notes.md <<'EOF'
$PF origin main
EOF"
want allow "an indented heredoc body" "$repo" "cat > notes.md <<-EOF
	rm -rf /
	EOF"
want ask "a force push AFTER a heredoc" "$repo" "cat > notes.md <<'EOF'
hello
EOF
$PF origin main"
want allow "dry-run force push" "$repo" "git"" push --dry-run --force origin main"
want allow "dry-run -n force push" "$repo" "git"" push -n -f origin main"

# Flag spellings git accepts (finding 3).
want ask "clustered -fu" "$repo" "git"" push -fu origin main"
want ask "clustered -uf" "$repo" "git"" push -uf origin main"
want ask "+refspec" "$repo" "git"" push origin +main"
want ask "clustered -fd" "$repo" "git"" push -fd origin feature/x"
want ask "--force --delete on branch" "$repo" "git"" branch --force --delete feature/x"
want ask "--delete --force on branch" "$repo" "git"" branch --delete --force feature/x"
want ask "-d -f on branch" "$repo" "git"" branch -d -f feature/x"

# git's global options between `git` and the subcommand (finding 6) -- the
# fragment lib/target.sh defines for both hooks, so `-C <dir>` is a spelling
# the gate sees and not only a scope the resolver understands.
want ask "-C then force push" "$repo" "git"" -C $repo push --force origin main"
want ask "--no-pager then hard reset" "$repo" "git"" --no-pager reset --hard HEAD~3"
want ask "-c then force push" "$repo" "git"" -c core.pager=cat push --force origin main"
want ask "-P then -f" "$repo" "git"" -P push -f origin main"
want ask "--git-dir= then filter-repo" "$repo" "git"" --git-dir=$repo/.git filter-repo --force"
want allow "-C then plain push" "$repo" "git"" -C $repo push origin feature/x"
want allow "--no-pager then log" "$repo" "git"" --no-pager log --oneline"

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

# ...and anything unexpected allows rather than erroring -- and says nothing
# on stderr either: jq's own parse error used to leak before the ERR trap ran.
for bad in 'not json at all' '' '{' '{"tool_name":"Bash"}' '{"tool_name":"Bash","tool_input":{}}'; do
  st=0
  out="$(printf '%s' "$bad" | bash "$HOOK" 2>"$tmp/bad.err")" || st=$?
  [[ "$st" -eq 0 ]] || fail "the hook exited $st on payload: $bad"
  [[ -z "${out//[[:space:]]/}" ]] || fail "did not fail open on payload: $bad"
  [[ ! -s "$tmp/bad.err" ]] || fail "wrote to stderr on payload '$bad': $(cat "$tmp/bad.err")"
done

echo "irreversible policy tests: passed"
