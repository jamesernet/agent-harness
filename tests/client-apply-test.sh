#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-client-apply.XXXXXX")"
tmp="$(cd "$tmp" && pwd)"
export HOME="$tmp/home"
export GIT_CONFIG_GLOBAL="$tmp/global.gitconfig"
mkdir -p "$HOME/.claude" "$HOME/.claude-acme"

fail() {
  echo "client apply test failed: $*" >&2
  exit 1
}

# The shipped example profile parses: with no account registered yet it must
# fail on exactly that, not on the TOML.
out="$("$SRC/bin/llmctx" client apply "$SRC/templates/client-profile.example.toml" 2>&1 || true)"
grep -q 'not registered' <<<"$out" || fail "example profile did not reach the account check: $out"

git config --global --add llmctx.claudeAccount "acme=$HOME/.claude-acme"

profile="$tmp/acme.toml"
cat >"$profile" <<'TOML'
# a comment
[client]
slug = "acme"   # trailing comment
name = "Acme Financial Ltd"

[ai]
agents_allowed = true
account = "acme"
models = ["opus", "sonnet"]   # aliases
max_effort = "high"

[infra]
kubeconfig = "~/.kube/configs/acme.yaml"
TOML

# Existing local settings must survive untouched.
printf '%s\n' '{"theme":"dark","permissions":{"allow":["Private(x)"]},"maxEffortLevel":"xhigh"}' >"$HOME/.claude-acme/settings.json"

if "$SRC/bin/llmctx" client apply "$profile" --check >/dev/null 2>&1; then
  fail "--check reported current before anything was applied"
fi
"$SRC/bin/llmctx" client apply "$profile" >/dev/null || fail "apply failed"
s="$HOME/.claude-acme/settings.json"
jq -e '.availableModels == ["opus","sonnet"] and .enforceAvailableModels == true and .maxEffortLevel == "high"' "$s" >/dev/null ||
  fail "policy keys were not written"
jq -e '.theme == "dark" and .permissions.allow == ["Private(x)"]' "$s" >/dev/null || fail "unrelated keys were not preserved"
jq -e 'has("availableModels") | not' "$HOME/.claude/settings.json" >/dev/null 2>&1 || [[ ! -f "$HOME/.claude/settings.json" ]] ||
  fail "policy leaked into the default account"
"$SRC/bin/llmctx" client apply "$profile" --check >/dev/null || fail "--check did not report current after apply"

# Hand-edit downstream is drift, and --check changes nothing.
jq '.maxEffortLevel = "max"' "$s" >"$s.tmp" && mv "$s.tmp" "$s"
if "$SRC/bin/llmctx" client apply "$profile" --check >/dev/null 2>&1; then
  fail "--check missed drift"
fi
jq -e '.maxEffortLevel == "max"' "$s" >/dev/null || fail "--check modified the file"
"$SRC/bin/llmctx" client apply "$profile" >/dev/null
jq -e '.maxEffortLevel == "high"' "$s" >/dev/null || fail "re-apply did not restore the policy"

# Only declared keys are managed: a profile with max_effort alone leaves models alone.
sed -i.bak '/^models/d' "$profile" && rm -f "$profile.bak"
"$SRC/bin/llmctx" client apply "$profile" >/dev/null || fail "effort-only profile failed"
jq -e '.availableModels == ["opus","sonnet"]' "$s" >/dev/null || fail "undeclared key was removed"

# Validation refuses rather than guesses.
bad="$tmp/bad.toml"
printf '[ai]\naccount = "acme"\nmax_effort = "turbo"\n' >"$bad"
"$SRC/bin/llmctx" client apply "$bad" >/dev/null 2>&1 && fail "bad effort was accepted"
printf '[ai]\naccount = "acme"\nmodels = ["gpt-5"]\n' >"$bad"
"$SRC/bin/llmctx" client apply "$bad" >/dev/null 2>&1 && fail "non-claude model was accepted"
printf '[ai]\naccount = "nobody"\nmax_effort = "high"\n' >"$bad"
"$SRC/bin/llmctx" client apply "$bad" >/dev/null 2>&1 && fail "unregistered account was accepted"
printf '[ai]\nmax_effort = "high"\n' >"$bad"
"$SRC/bin/llmctx" client apply "$bad" >/dev/null 2>&1 && fail "missing account was accepted"
printf '[ai]\naccount = "acme"\nagents_allowed = true\n' >"$bad"
"$SRC/bin/llmctx" client apply "$bad" >/dev/null 2>&1 && fail "profile with no policy keys was accepted"
"$SRC/bin/llmctx" client apply "$tmp/missing.toml" >/dev/null 2>&1 && fail "missing file was accepted"
"$SRC/bin/llmctx" client frobnicate >/dev/null 2>&1 && fail "unknown subcommand was accepted"

echo "client apply tests: passed"
