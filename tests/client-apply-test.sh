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

# All three keys are managed: dropping models from the profile lifts the restriction.
sed -i.bak '/^models/d' "$profile" && rm -f "$profile.bak"
if "$SRC/bin/llmctx" client apply "$profile" --check >/dev/null 2>&1; then
  fail "--check reported current while a stale allowlist was still enforced"
fi
"$SRC/bin/llmctx" client apply "$profile" >/dev/null || fail "effort-only profile failed"
jq -e '(has("availableModels") | not) and (has("enforceAvailableModels") | not) and .maxEffortLevel == "high"' "$s" >/dev/null ||
  fail "dropping models did not lift the restriction"
"$SRC/bin/llmctx" client apply "$profile" --check >/dev/null || fail "--check not current after lifting the restriction"

# An empty settings file used to make apply a silent no-op that reported
# success; it is now treated as {} and becomes a valid object.
: >"$s"
"$SRC/bin/llmctx" client apply "$profile" >/dev/null || fail "apply onto an empty file failed"
jq -e 'type == "object" and .maxEffortLevel == "high"' "$s" >/dev/null || fail "empty file did not become a valid settings object"
printf '%s\n' '[]' >"$s"
"$SRC/bin/llmctx" client apply "$profile" >/dev/null 2>&1 && fail "non-object settings were accepted"
printf '%s\n' '{}' >"$s"

# Claude Code's own aliases, with a context suffix, are expressible.
bad="$tmp/bad.toml"
printf '[ai]\naccount = "acme"\nmodels = ["opusplan", "sonnet[1m]", "default"]\n' >"$bad"
"$SRC/bin/llmctx" client apply "$bad" >/dev/null || fail "real model aliases were refused"

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
