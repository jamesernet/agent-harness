#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-agents-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd)"
fixture="$tmp/source"
mkdir -p "$fixture/bin/lib" "$fixture/agents"
cp "$SRC/bin/llmctx" "$SRC/bin/install-agents.sh" "$fixture/bin/"
cp "$SRC/bin/lib/skills.sh" "$SRC/bin/lib/accounts.sh" "$fixture/bin/lib/"
agent() { printf -- '---\nname: %s\ndescription: %s\nmodel: haiku\n---\n\n%s\n' "$1" "$1 agent" "${2:-body}"; }
agent alpha >"$fixture/agents/alpha.md"
agent beta >"$fixture/agents/beta.md"
printf '%s\n' '# not an agent' >"$fixture/agents/README.md"
git -C "$fixture" init -q
export GIT_CONFIG_GLOBAL="$tmp/global.gitconfig"

fail() {
  echo "agent install test failed: $*" >&2
  exit 1
}

home="$tmp/home"
HOME="$home" "$fixture/bin/llmctx" agents install >/dev/null
target="$home/.claude/agents"
[[ -f "$target/alpha.md" && -f "$target/beta.md" ]] || fail "agents were not installed"
[[ ! -e "$target/README.md" ]] || fail "README was installed as an agent"
[[ ! -e "$home/.codex/agents" ]] || fail "agents were installed for Codex, which has no subagent format"
jq -e '.schemaVersion == 1 and .managedBy == "jamesernet/llm-context" and .mode == "copy" and (.agents.alpha.contentHash | length) == 64' \
  "$target/.llmctx-managed.json" >/dev/null || fail "manifest is invalid"

agent alpha "updated body" >"$fixture/agents/alpha.md"
HOME="$home" "$fixture/bin/llmctx" agents install >/dev/null
cmp "$fixture/agents/alpha.md" "$target/alpha.md" >/dev/null || fail "managed agent was not updated"

HOME="$home" "$fixture/bin/llmctx" agents install --dev >/dev/null
[[ -L "$target/alpha.md" && "$(readlink "$target/alpha.md")" == "$fixture/agents/alpha.md" ]] ||
  fail "development mode did not link the agent"
HOME="$home" "$fixture/bin/llmctx" agents install >/dev/null
[[ -f "$target/alpha.md" && ! -L "$target/alpha.md" ]] || fail "development link did not switch back to a copy"

rm "$fixture/agents/beta.md"
HOME="$home" "$fixture/bin/llmctx" agents install >/dev/null
[[ ! -e "$target/beta.md" ]] || fail "retired managed agent was not pruned"
jq -e '.agents | has("beta") | not' "$target/.llmctx-managed.json" >/dev/null || fail "manifest kept the retired agent"

# A file the installer did not write is somebody else's: preserved, and a
# collision with a new source name is a conflict rather than an overwrite.
printf '%s\n' 'mine' >"$target/mine.md"
HOME="$home" "$fixture/bin/llmctx" agents install >/dev/null
[[ "$(cat "$target/mine.md")" == "mine" ]] || fail "unmanaged agent was changed"
agent mine >"$fixture/agents/mine.md"
if HOME="$home" "$fixture/bin/llmctx" agents install >/dev/null 2>&1; then
  fail "unmanaged file conflict was accepted"
fi
[[ "$(cat "$target/mine.md")" == "mine" ]] || fail "conflicting unmanaged agent was overwritten"
rm "$fixture/agents/mine.md"

# Every registered account gets the set.
acme_dir="$home/.claude-acme"
git config --global --add llmctx.claudeAccount "acme=$acme_dir"
HOME="$home" "$fixture/bin/llmctx" agents install >/dev/null
[[ -f "$acme_dir/agents/alpha.md" ]] || fail "registered account did not get the agents"
HOME="$home" "$fixture/bin/llmctx" agents install --account acme >/dev/null || fail "--account narrowing failed"
git config --global --unset-all llmctx.claudeAccount

if HOME="$home" "$fixture/bin/llmctx" agents install --unknown >/dev/null 2>&1; then
  fail "unknown option was accepted"
fi
if HOME="$home" "$fixture/bin/llmctx" agents list >/dev/null 2>&1; then
  fail "unknown subcommand was accepted"
fi

# The shipped definitions install and lint from this checkout.
real_home="$tmp/real-home"
HOME="$real_home" "$SRC/bin/install-agents.sh" >/dev/null 2>&1 || fail "shipped agents failed to install"
shipped="$(find "$SRC/agents" -maxdepth 1 -name '*.md' ! -name README.md | wc -l | tr -d ' ')"
installed="$(find "$real_home/.claude/agents" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
[[ "$shipped" == "$installed" ]] || fail "shipped $shipped agents, installed $installed"

echo "agent install tests: passed"
