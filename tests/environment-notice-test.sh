#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$SRC/bin/claude-hooks/environment-notice.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-env-notice.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
export GIT_CONFIG_GLOBAL="$tmp/global.gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$tmp/home" "$tmp/repo/pkg" "$tmp/other"
git -C "$tmp/repo" init -q
git -C "$tmp/other" init -q
for variable in AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_ROLE_SESSION_NAME AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_AUTHORIZATION_TOKEN AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE; do unset "$variable"; done
fail() {
  echo "environment notice test failed: $*" >&2
  exit 1
}
payload() { jq -cn --arg cwd "$tmp/repo/pkg" '{cwd:$cwd}'; }
run() { env HOME="$tmp/home" "$@" bash "$HOOK" <<<"$(payload)"; }
fired() { jq -e '.hookSpecificOutput.hookEventName == "SessionStart" and (.hookSpecificOutput.additionalContext | contains("Stop work")) and (.systemMessage | length > 0)' <<<"$1" >/dev/null 2>&1; }
[[ -z "$(run AWS_PROFILE=somewhere-else)" ]] || fail "unbound context was judged"
cat >"$tmp/context.toml" <<'TOML'
[context]
id = "fixture"
[cloud]
aws_profile = "fixture-read"
aws_write_profile = "fixture-step-up"
[ai]
allow_code_egress = true
TOML
git -C "$tmp/repo" config llmctx.contextProfile "$tmp/context.toml"
[[ -z "$(run AWS_PROFILE=fixture-read AWS_SHARED_CREDENTIALS_FILE=/dev/null)" ]] || fail "matching ambient profile fired"
fired "$(run)" || fail "missing profile was not reported"
fired "$(run AWS_PROFILE=fixture-step-up)" || fail "step-up profile was not reported"
fired "$(run AWS_PROFILE=fixture-read AWS_DEFAULT_PROFILE=elsewhere)" || fail "default-profile override escaped"

# Values are inspected only for presence, never included in either message.
for variable in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_ROLE_SESSION_NAME AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_AUTHORIZATION_TOKEN AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE; do
  out="$(run AWS_PROFILE=fixture-read "$variable=fixture-private-value-never-print")"
  fired "$out" || fail "$variable was not reported"
  [[ "$out" == *"$variable"* ]] || fail "$variable was not named"
  [[ "$out" != *"fixture-private-value-never-print"* ]] || fail "$variable value leaked"
done

# The portable command returns failure on the same finding, unlike a hook
# whose notice must exit zero. It works from a package directory too.
if HOME="$tmp/home" AWS_PROFILE=fixture-step-up "$SRC/bin/llmctx" env session "$tmp/repo/pkg" >"$tmp/cli.log"; then fail "portable preflight approved a step-up profile"; fi
grep -q 'AWS_PROFILE' "$tmp/cli.log" || fail "portable check omitted its finding"
HOME="$tmp/home" AWS_PROFILE=fixture-read "$SRC/bin/llmctx" env session "$tmp/repo/pkg" >/dev/null || fail "portable preflight rejected a matching profile"
# A hook's inherited Git pointers cannot swap in an unbound repository.
fired "$(run AWS_PROFILE=fixture-step-up GIT_DIR="$tmp/other/.git" GIT_WORK_TREE="$tmp/other")" || fail "inherited Git environment selected another policy"

# env check must also resolve the explicit directory's policy, independently
# of inherited Git pointers. A profile which differs from that context is a
# policy conflict even if the inherited repository has no binding at all.
printf '{"schemaVersion":1,"environment":{"target":"other","cloud":{"awsProfile":"fixture-step-up"}}}\n' >"$tmp/repo/.llmctx.json"
set +e
out="$(HOME="$tmp/home" GIT_DIR="$tmp/other/.git" GIT_WORK_TREE="$tmp/other" "$SRC/bin/llmctx" env check "$tmp/repo" 2>&1)"
status=$?
set -e
[[ "$status" -eq 1 && "$out" == *"CONFLICT aws:ambient-policy"* ]] || fail "env check used inherited policy: $out"

# No ambient role means no role is available by default, not an implicit
# personal/default profile. WorkStation's explicit unbound sentinel is safe.
printf '[context]\nid="no-aws"\n' >"$tmp/context.toml"
[[ -z "$(run)" ]] || fail "empty AWS environment fired in no-AWS context"
[[ -z "$(run AWS_PROFILE=__workstation_unbound__)" ]] || fail "unbound sentinel fired"
fired "$(run AWS_PROFILE=default)" || fail "ambient default profile escaped in no-AWS context"
# Policy parse failures are reported without source contents or execution.
printf '[cloud]\naws_profile="$(touch should-not-exist)"\n' >"$tmp/context.toml"
out="$(run AWS_PROFILE=fixture-read)"
fired "$out" || fail "invalid bound policy was silently approved"
[[ "$out" != *'$(touch'* && ! -e should-not-exist ]] || fail "private policy was echoed or executed"
[[ -z "$(HOME="$tmp/home" bash "$HOOK" <<<'not JSON' 2>/dev/null)" ]] || fail "invalid hook payload produced a notice"
[[ -z "$(HOME="$tmp/home" bash "$HOOK" <<<'{"cwd":[]}' 2>/dev/null)" ]] || fail "non-string cwd produced a notice"

# Install only into the disposable home. Both libraries and the registered
# hook must work there, and unrelated SessionStart entries survive the merge.
printf '[cloud]\naws_profile="fixture-read"\n' >"$tmp/context.toml"
mkdir -p "$tmp/home/.claude"
printf '{"theme":"light","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/foreign/startup.sh"}]}]}}\n' >"$tmp/home/.claude/settings.json"
HOME="$tmp/home" LLMCTX_ALLOW_WORKTREE_INSTALL=1 "$SRC/bin/build-adapters.sh" --account default >/dev/null
settings="$tmp/home/.claude/settings.json"
jq -e '.theme == "light" and ([.hooks.SessionStart[].hooks[].command] | any(contains("environment-notice.sh"))) and ([.hooks.SessionStart[].hooks[].command] | index("/foreign/startup.sh") != null)' "$settings" >/dev/null || fail "hook registration lost managed or foreign settings"
out="$(HOME="$tmp/home" AWS_PROFILE=fixture-step-up bash "$tmp/home/.claude/hooks/environment-notice.sh" <<<"$(payload)")"
fired "$out" || fail "installed hook could not load its context libraries"
HOME="$tmp/home" LLMCTX_ALLOW_WORKTREE_INSTALL=1 "$SRC/bin/build-adapters.sh" --check --account default >/dev/null || fail "installed hook libraries report drift"
echo 'environment notice tests: passed'
