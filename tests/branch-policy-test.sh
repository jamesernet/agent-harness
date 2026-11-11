#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$SRC/bin/claude-hooks/branch-policy.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-branch-test.XXXXXX")"
repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" symbolic-ref HEAD refs/heads/main
export GIT_CONFIG_GLOBAL="$tmp/global.gitconfig"

fail() {
  echo "branch policy test failed: $*" >&2
  exit 1
}

run_hook() {
  (cd "$repo" && printf '%s' '{"tool_name":"Edit","session_id":"test"}' | "$HOOK")
}

printf '%s\n' '{"schemaVersion":1,"profile":"client"}' >"$repo/.llmctx.json"
output="$(run_hook)"
[[ "$output" == *'"permissionDecision": "deny"'* ]] || fail "client policy did not deny"

git -C "$repo" config --local llmctx.branchPolicy off
[[ -z "$(run_hook)" ]] || fail "local off override did not allow"
git -C "$repo" config --local --unset llmctx.branchPolicy

printf '%s\n' '{"schemaVersion":99,"profile":"client"}' >"$repo/.llmctx.json"
[[ -z "$(run_hook)" ]] || fail "invalid policy did not fail open"

printf '%s\n' '{"schemaVersion":1,"profile":"client"}' >"$repo/.llmctx.json"
git -C "$repo" symbolic-ref HEAD refs/heads/feature/test
[[ -z "$(run_hook)" ]] || fail "feature branch was blocked"

# --- scope: judge the TARGET, not where the session stands -------------------
#
# This hook used to resolve the repository from the process cwd and judge that
# repository's branch whatever the tool was touching. Two false denials
# followed, both hard blocks under `deny`, and neither action broke the rule.

git -C "$repo" symbolic-ref HEAD refs/heads/main
printf '%s\n' '{"schemaVersion":1,"profile":"client"}' >"$repo/.llmctx.json"

hook_with() { printf '%s' "$1" | "$HOOK"; }
decision() { printf '%s' "$1" | "$HOOK" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo allow; }

# Misfire 1: a file outside any git repository is none of this hook's business.
outside="$(mktemp -d)"
payload="$(jq -nc --arg c "$repo" --arg f "$outside/scratch.txt" \
  '{tool_name:"Edit",session_id:"t",tool_input:{file_path:$f},cwd:$c}')"
[[ -z "$(hook_with "$payload")" ]] ||
  fail "denied an edit to a file outside any repository"
rm -rf "$outside"

# Misfire 2: pushing a feature branch is how work is published. Naming an
# unprotected ref must not be blocked just because the checkout sits on main.
payload="$(jq -nc --arg c "$repo" \
  '{tool_name:"Bash",session_id:"t",tool_input:{command:"git push origin feature/x"},cwd:$c}')"
[[ -z "$(hook_with "$payload")" ]] ||
  fail "denied pushing an unprotected branch"

# The rule itself must survive all of the above.
payload="$(jq -nc --arg c "$repo" --arg f "$repo/README.md" \
  '{tool_name:"Edit",session_id:"t",tool_input:{file_path:$f},cwd:$c}')"
[[ "$(decision "$payload")" == deny ]] ||
  fail "an edit inside the protected checkout was allowed"

# Relative paths resolve against the payload cwd, or every relative edit escapes.
payload="$(jq -nc --arg c "$repo" \
  '{tool_name:"Edit",session_id:"t",tool_input:{file_path:"README.md"},cwd:$c}')"
[[ "$(decision "$payload")" == deny ]] ||
  fail "a relative-path edit inside the protected checkout was allowed"

for c in "git commit -m x" "git push" "git push origin main"; do
  payload="$(jq -nc --arg c "$repo" --arg cmd "$c" \
    '{tool_name:"Bash",session_id:"t",tool_input:{command:$cmd},cwd:$c}')"
  [[ "$(decision "$payload")" == deny ]] || fail "allowed '$c' on a protected branch"
done

# --- global git options between `git` and the subcommand (#79) --------------
#
# `git -C <dir> commit` is the spelling lib/target.sh resolves as the TARGET,
# and for months the action matcher could not see it, so the one spelling the
# scope code handled most carefully never reached the gate. The option forms
# must be judged exactly as their bare equivalents, under every policy value.
# Negative first: each spelling IS caught on the protected checkout. These
# payloads stand IN the protected repository; the --git-dir rows depend on
# that, because the scope resolver reads -C and cd but not --git-dir, so from
# elsewhere they fall back to the cwd (see the issue filed from PR #96's review).
for c in \
  "git -C $repo commit -m x" \
  "git -C $repo push" \
  "git -C $repo push origin main" \
  "git -c user.name=t commit -m x" \
  "git -c user.name=t -c user.email=t@t push" \
  "git --no-pager commit -m x" \
  "git --git-dir=$repo/.git commit -m x" \
  "git --git-dir $repo/.git push" \
  "git -C $repo --no-pager -c core.pager=cat commit -m x" \
  "cd /tmp && git -C $repo commit -m x" \
  "sudo git -C $repo push" \
  "git -P commit -m x" \
  "git -p -C $repo commit -m x" \
  "GIT_TRACE=1 git commit -m x" \
  "GIT_DIR=$repo/.git git -C $repo push"; do
  payload="$(jq -nc --arg c "$repo" --arg cmd "$c" \
    '{tool_name:"Bash",session_id:"t",tool_input:{command:$cmd},cwd:$c}')"
  [[ "$(decision "$payload")" == deny ]] || fail "allowed '$c' on a protected branch (#79)"
done
# Positive: the option forms are not false positives — a non-mutating
# subcommand behind the same options, and the words inside other commands.
for c in \
  "git -C $repo status" \
  "git -C $repo log --oneline" \
  "git --no-pager -C $repo diff" \
  "echo 'git -C $repo commit'" \
  "grep -r 'git -c x=y push' ." \
  "git commit-tree HEAD^{tree} -m x" \
  "git -C $repo commit-graph write" \
  "git -C $repo push-to-nowhere"; do
  payload="$(jq -nc --arg c "$repo" --arg cmd "$c" \
    '{tool_name:"Bash",session_id:"t",tool_input:{command:$cmd},cwd:$c}')"
  [[ -z "$(hook_with "$payload")" ]] || fail "denied '$c', which mutates nothing"
done
# The refspec exemption must see the same prefix the gate does: a push that
# names an unprotected branch is how work is published, with or without -C.
for c in \
  "git -C $repo push -u origin feature/x" \
  "git -c push.default=current push origin feature/x" \
  "git --no-pager push origin HEAD:feature/x"; do
  payload="$(jq -nc --arg c "$repo" --arg cmd "$c" \
    '{tool_name:"Bash",session_id:"t",tool_input:{command:$cmd},cwd:$c}')"
  [[ -z "$(hook_with "$payload")" ]] || fail "denied '$c', which pushes an unprotected branch"
done
# Under every policy value, the option form decides exactly as the bare form.
# Fresh session ids, because `remind` fires once per session and would make
# the second call differ from the first for a reason that is not the spelling.
for policy in off remind ask deny; do
  git -C "$repo" config --local llmctx.branchPolicy "$policy"
  bare="$(decision "$(jq -nc --arg c "$repo" --arg cmd "git commit -m x" \
    '{tool_name:"Bash",session_id:"bare-\($cmd)",tool_input:{command:$cmd},cwd:$c}')")"
  dashc="$(decision "$(jq -nc --arg c "$repo" --arg cmd "git -C $repo commit -m x" \
    '{tool_name:"Bash",session_id:"opt-\($cmd)",tool_input:{command:$cmd},cwd:$c}')")"
  [[ "$bare" == "$dashc" ]] ||
    fail "under $policy, 'git -C <dir> commit' decided $dashc but bare decided $bare"
  git -C "$repo" config --local --unset llmctx.branchPolicy
done

# A push naming a DIFFERENT repository is judged by that repository's branch.
other="$(mktemp -d)"
git -C "$other" init -q -b main
git -C "$other" symbolic-ref HEAD refs/heads/feature/elsewhere
payload="$(jq -nc --arg c "$repo" --arg cmd "git -C $other push -u origin feature/elsewhere" \
  '{tool_name:"Bash",session_id:"t",tool_input:{command:$cmd},cwd:$c}')"
[[ -z "$(hook_with "$payload")" ]] ||
  fail "denied a push to another repository that is on a feature branch"
rm -rf "$other"

# --- leading `cd <dir> &&` --------------------------------------------------
#
# The most common way an agent operates on another repository, and it was being
# judged against wherever the session stood. Leading only, one level: chasing
# `cd` through a pipeline or a subshell needs a shell parser, and a guard that
# half-parses shell is wrong in both directions.
#
# GC is built rather than written literally so this file can be edited and run
# by an agent without the string tripping the guard under test.
GC="git"" commit -m x"

feature_repo="$(mktemp -d)"
git -C "$feature_repo" init -q -b main
git -C "$feature_repo" symbolic-ref HEAD refs/heads/feature/elsewhere
printf '%s\n' '{"schemaVersion":1,"profile":"client"}' >"$feature_repo/.llmctx.json"

bash_payload() { jq -nc --arg c "$1" --arg cmd "$2" \
  '{tool_name:"Bash",session_id:"t",tool_input:{command:$cmd},cwd:$c}'; }

# cd into a repo on a feature branch: allowed, whatever this repo is on.
[[ -z "$(hook_with "$(bash_payload "$repo" "cd $feature_repo && $GC")")" ]] ||
  fail "denied a commit in a repo on a feature branch reached by a leading cd"

# Quoted path, and `;` as the separator, are the same case.
[[ -z "$(hook_with "$(bash_payload "$repo" "cd \"$feature_repo\" && $GC")")" ]] ||
  fail "denied a leading cd with a quoted path"
[[ -z "$(hook_with "$(bash_payload "$repo" "cd $feature_repo ; $GC")")" ]] ||
  fail "denied a leading cd separated by ;"

# cd into a repo on a PROTECTED branch: still denied. The rule follows the
# target, which is the whole point — it does not simply stop applying.
[[ "$(decision "$(bash_payload "$feature_repo" "cd $repo && $GC")")" == deny ]] ||
  fail "allowed a commit in a protected checkout reached by a leading cd"

# A cd that BEGINS A STATEMENT is followed wherever it sits, and the LAST one
# wins -- which is what the shell does for sequential statements.
#
# This replaced a leading-only rule, and the reason was not convenience. Measured
# against the previous hook, leading-only ALLOWED the third case below: the second
# cd is the one the shell honours, so the commit landed on the protected branch
# and the guard passed it. Following the last cd fixes the false positive in the
# first two cases and closes that hole with the same rule.
[[ -z "$(hook_with "$(bash_payload "$repo" "ls && cd $feature_repo && $GC")")" ]] ||
  fail "denied a commit reached by a cd after an && prefix"
[[ -z "$(hook_with "$(bash_payload "$repo" "lsof -ti :3211 | xargs -r kill -9; cd $feature_repo && $GC")")" ]] ||
  fail "denied a commit reached by a cd after a pipeline and a ; (moorerunway.com#68)"
[[ "$(decision "$(bash_payload "$repo" "cd $feature_repo && cd $repo && $GC")")" == deny ]] ||
  fail "the LAST cd did not win: a commit on a protected branch was allowed"

# A subshell is still a statement boundary, so the cd inside one is seen.
[[ -z "$(hook_with "$(bash_payload "$repo" "(cd $feature_repo && $GC)")")" ]] ||
  fail "denied a commit inside a subshell that cd-ed first"

# But a cd inside a command substitution must NOT be followed: it runs in its own
# subshell, its directory never reaches the outer command, and the commit lands
# where the session stands. Honouring it would scope the guard to a directory the
# git write never touches.
[[ "$(decision "$(bash_payload "$repo" "$GC -m \"\$(cd $feature_repo && pwd)\"")")" == deny ]] ||
  fail "followed a cd inside a command substitution"

# `W=<path>; cd "$W"` on ONE line. The assignment is not at end-of-line here, so
# the variable lookup has to normalise separators the same way the cd match does.
[[ -z "$(hook_with "$(bash_payload "$repo" "W=$feature_repo; cd \"\$W\" && $GC")")" ]] ||
  fail "did not resolve a variable assigned before a ; on the same line"

# A cd to somewhere that does not exist falls back to the session, not to allow.
[[ "$(decision "$(bash_payload "$repo" "cd /no/such/dir && $GC")")" == deny ]] ||
  fail "a cd to a nonexistent directory did not fall back to the session repo"

# `cd "$VAR"` where VAR was assigned earlier in the same command. The dominant
# way an agent addresses a worktree, and until this was handled the capture
# returned the literal string "$WT", failed the directory test, and fell back to
# the session — denying every commit made from every worktree of a repo whose
# primary checkout sat on the trunk.
[[ -z "$(hook_with "$(bash_payload "$repo" "$(printf 'WT=%s\ncd "$WT" && %s' "$feature_repo" "$GC")")")" ]] ||
  fail "denied a cd to a variable assigned in the same command"

# Braced form.
[[ -z "$(hook_with "$(bash_payload "$repo" "$(printf 'WT=%s\ncd "${WT}" && %s' "$feature_repo" "$GC")")")" ]] ||
  fail "denied a cd to a braced variable"

# Same idiom, but the target is on a protected branch: still denied. Resolving
# the variable must not become a way past the rule.
[[ "$(decision "$(bash_payload "$feature_repo" "$(printf 'WT=%s\ncd "$WT" && %s' "$repo" "$GC")")")" == deny ]] ||
  fail "allowed a commit in a protected checkout reached by a variable cd"

# A variable that was never assigned in this command is not guessable, so it
# falls back to the session rather than inventing a target.
[[ "$(decision "$(bash_payload "$repo" "$(printf 'cd "$NOPE" && %s' "$GC")")")" == deny ]] ||
  fail "an unassigned variable did not fall back to the session repo"

# `cd <dir>` terminated by a newline rather than `&&`. The most ordinary shape a
# multi-line script has, and requiring `&&` sent it to the session repo.
[[ -z "$(hook_with "$(bash_payload "$repo" "$(printf 'cd %s\n%s' "$feature_repo" "$GC")")")" ]] ||
  fail "denied a cd terminated by a newline"

# The variable form of the same thing, which is what an agent actually writes.
[[ -z "$(hook_with "$(bash_payload "$repo" "$(printf 'WT=%s\ncd "$WT"\n%s' "$feature_repo" "$GC")")")" ]] ||
  fail "denied a variable cd terminated by a newline"

# Still follows the target: newline-terminated cd into a protected checkout is denied.
[[ "$(decision "$(bash_payload "$feature_repo" "$(printf 'cd %s\n%s' "$repo" "$GC")")")" == deny ]] ||
  fail "allowed a commit in a protected checkout reached by a newline cd"

rm -rf "$feature_repo"

# --- LINKED WORKTREES -------------------------------------------------------
#
# The arrangement this whole convention pushes you into: a primary checkout that
# sits on the trunk by design, and a linked worktree per branch. Every decision
# below must depend on the checkout that owns the target and NOT on where the
# hook process happens to be standing, so each is run from a deliberately
# unhelpful cwd.

wt_main="$(mktemp -d)/primary"
mkdir -p "$wt_main"
git -C "$wt_main" init -q -b main
printf '%s\n' '{"schemaVersion":1,"profile":"client"}' >"$wt_main/.llmctx.json"
git -C "$wt_main" add -A
git -C "$wt_main" -c user.email=t@t -c user.name=t commit -qm init
wt_feature="$(dirname "$wt_main")/wt-feature"
git -C "$wt_main" worktree add -q -b feature/wt "$wt_feature"

edit_payload() { jq -nc --arg c "$1" --arg f "$2" \
  '{tool_name:"Edit",session_id:"t",tool_input:{file_path:$f},cwd:$c}'; }

# 1. A session in a linked worktree edits its own files while the PRIMARY
#    checkout sits on main. Allowed — the primary's HEAD is not this edit's
#    business, and judging it there blocked every worktree at once.
[[ -z "$(cd / && hook_with "$(edit_payload "$wt_feature" "$wt_feature/note.md")")" ]] ||
  fail "denied an edit in a linked worktree while the primary checkout was on main"

# A file that does not exist yet is the common case for Write — the parent walk
# must still land in the worktree rather than giving up and falling back.
[[ -z "$(cd / && hook_with "$(edit_payload "$wt_feature" "$wt_feature/does/not/exist/yet.md")")" ]] ||
  fail "denied a new file in a linked worktree"

# 2. The rule still applies to a checkout that IS on a protected branch, even
#    when the session is standing in a feature worktree.
[[ "$(cd / && decision "$(edit_payload "$wt_feature" "$wt_main/README.md")")" == deny ]] ||
  fail "allowed an edit in a checkout on main from a feature worktree session"

# 3. The denial has to name the branch AND the checkout it read it from.
#    Naming only the branch, to a session that can see it is on another one,
#    reads as a broken guard — and the fix people reach for is `off`.
msg="$(cd / && hook_with "$(edit_payload "$wt_feature" "$wt_main/README.md")" |
  jq -r '.hookSpecificOutput.permissionDecisionReason')"
[[ "$msg" == *'"main"'* ]] || fail "denial did not name the branch"
[[ "$msg" == *"$wt_main"* ]] || fail "denial did not name the checkout it was read from"
[[ "$msg" == *"not this session's directory"* ]] ||
  fail "denial did not flag that the branch came from another checkout"

# A merge in progress legitimately edits the trunk, and the exemption must not
# depend on the hook's cwd either. `--git-path .` answered relatively, so this
# was denied from anywhere but the repository root.
git -C "$wt_main" checkout -q -b side
echo side >"$wt_main/conflict.txt"
git -C "$wt_main" add -A
git -C "$wt_main" -c user.email=t@t -c user.name=t commit -qm side
git -C "$wt_main" checkout -q main
echo main >"$wt_main/conflict.txt"
git -C "$wt_main" add -A
git -C "$wt_main" -c user.email=t@t -c user.name=t commit -qm main
git -C "$wt_main" -c user.email=t@t -c user.name=t merge side >/dev/null 2>&1 || true
[[ -e "$wt_main/.git/MERGE_HEAD" ]] || fail "test setup: no merge in progress"
[[ -z "$(cd / && hook_with "$(edit_payload "$wt_feature" "$wt_main/conflict.txt")")" ]] ||
  fail "denied a conflict resolution mid-merge on the trunk"

# --- remind without shasum ----------------------------------------------------
#
# The once-per-session marker was keyed with `shasum`, which a minimal Linux
# does not ship. There the command substitution failed, the ERR trap exited 0,
# and `remind` -- this repository's own default -- silently became `off`. A
# guard that fails open cannot report its own absence, so this runs the hook
# with both hashing tools masked off PATH and asks for the reminder (#56).
minbin="$(mktemp -d)"
for tool in bash git jq grep sed awk cut cat find mkdir rm head tail tr sort uniq wc dirname basename cksum env; do
  real="$(command -v "$tool" 2>/dev/null)" || continue
  ln -sf "$real" "$minbin/$tool"
done
[[ ! -e "$minbin/shasum" && ! -e "$minbin/sha256sum" ]] || fail "test setup: a hashing tool leaked into the minimal PATH"
remind_repo="$(mktemp -d)"
git -C "$remind_repo" init -q -b main
printf '%s\n' '{"schemaVersion":1,"profile":"personal","branchPolicy":"remind"}' >"$remind_repo/.llmctx.json"
remind_payload="$(jq -nc --arg c "$remind_repo" --arg cmd "git commit -m x" \
  '{tool_name:"Bash",session_id:"no-shasum-session",tool_input:{command:$cmd},cwd:$c}')"
first="$(printf '%s' "$remind_payload" | PATH="$minbin" TMPDIR="$minbin/tmp" "$HOOK" 2>"$minbin/err")"
[[ "$first" == *'"permissionDecision": "ask"'* ]] ||
  fail "remind did not fire without shasum on PATH (output: ${first:-<empty>}; stderr: $(cat "$minbin/err")) -- the marker key fell open"
second="$(printf '%s' "$remind_payload" | PATH="$minbin" TMPDIR="$minbin/tmp" "$HOOK" 2>/dev/null)"
[[ -z "$second" ]] || fail "remind fired twice for one session -- the marker was not written: $second"
[[ -n "$(find "$minbin/tmp/claude-branch-policy" -type f 2>/dev/null)" ]] || fail "no marker file was written"
rm -rf "$minbin" "$remind_repo"

# --- fail open --------------------------------------------------------------
#
# A guard that blocks on a malformed payload gets removed, and then it protects
# nothing. Anything unexpected must allow.
for bad in 'not json at all' '' '{' '{"tool_name":"Edit"}' '{"tool_name":"Edit","tool_input":{}}'; do
  [[ -z "$(cd / && printf '%s' "$bad" | "$HOOK" 2>/dev/null || true)" ]] ||
    fail "did not fail open on payload: $bad"
done

git -C "$wt_main" worktree remove --force "$wt_feature" 2>/dev/null || true
rm -rf "$(dirname "$wt_main")"

echo "branch policy tests: passed"
