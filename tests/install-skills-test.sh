#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-skills-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd)"
fixture="$tmp/source"
mkdir -p "$fixture/bin/lib" "$fixture/skills/owned" "$fixture/vendor/vendored"
cp "$SRC/bin/llmctx" "$SRC/bin/account.sh" "$SRC/bin/install-skills.sh" "$fixture/bin/"
cp "$SRC/bin/lib/skills.sh" "$SRC/bin/lib/accounts.sh" "$fixture/bin/lib/"
printf '%s\n' '# Owned skill' >"$fixture/skills/owned/SKILL.md"
printf '%s\n' '# Vendored skill' >"$fixture/vendor/vendored/SKILL.md"
git -C "$fixture" init -q
export GIT_CONFIG_GLOBAL="$tmp/global.gitconfig"

fail() {
  echo "skill install test failed: $*" >&2
  exit 1
}

copy_home="$tmp/copy-home"
HOME="$copy_home" "$fixture/bin/llmctx" skills install >/dev/null
for target in "$copy_home/.claude/skills" "$copy_home/.codex/skills"; do
  [[ -d "$target/owned" && ! -L "$target/owned" ]] || fail "owned skill was not copied"
  [[ -d "$target/vendored" && ! -L "$target/vendored" ]] || fail "vendored skill was not copied"
  jq -e '.schemaVersion == 1 and .managedBy == "jamesernet/llm-context" and .mode == "copy" and (.contentHash | length) == 64' \
    "$target/owned/.llmctx-managed.json" >/dev/null || fail "copy metadata is invalid"
done

# Every registered Codex home receives the same managed skill contract as the
# default home. Credentials and unmanaged files remain outside this installer.
codex_acme="$copy_home/.codex-acme"
HOME="$copy_home" "$fixture/bin/llmctx" account add --provider codex acme "$codex_acme" >/dev/null
HOME="$copy_home" "$fixture/bin/llmctx" skills install >/dev/null
[[ -d "$codex_acme/skills/owned" ]] || fail "registered Codex home received no skills"
printf '%s\n' 'preserve me' >"$codex_acme/local.txt"
HOME="$copy_home" "$fixture/bin/llmctx" skills install >/dev/null
[[ "$(cat "$codex_acme/local.txt")" == "preserve me" ]] ||
  fail "Codex install changed an unmanaged file"

printf '%s\n' '# Updated owned skill' >"$fixture/skills/owned/SKILL.md"
HOME="$copy_home" "$fixture/bin/llmctx" skills install >/dev/null
cmp "$fixture/skills/owned/SKILL.md" "$copy_home/.claude/skills/owned/SKILL.md" >/dev/null ||
  fail "managed copy was not updated"

HOME="$copy_home" "$fixture/bin/llmctx" skills install --dev >/dev/null
[[ -L "$copy_home/.claude/skills/owned" ]] || fail "managed copy did not switch to development mode"
HOME="$copy_home" "$fixture/bin/llmctx" skills install >/dev/null
[[ -d "$copy_home/.claude/skills/owned" && ! -L "$copy_home/.claude/skills/owned" ]] ||
  fail "development link did not switch back to copy mode"

rm -rf "$fixture/vendor/vendored"
HOME="$copy_home" "$fixture/bin/llmctx" skills install >/dev/null
[[ ! -e "$copy_home/.claude/skills/vendored" ]] || fail "retired managed skill was not pruned"

mkdir -p "$fixture/skills/local" "$copy_home/.claude/skills/local"
printf '%s\n' '# Local source' >"$fixture/skills/local/SKILL.md"
printf '%s\n' 'keep me' >"$copy_home/.claude/skills/local/local.txt"
if HOME="$copy_home" "$fixture/bin/llmctx" skills install >/dev/null 2>&1; then
  fail "unmanaged directory conflict was accepted"
fi
[[ "$(cat "$copy_home/.claude/skills/local/local.txt")" == "keep me" ]] || fail "unmanaged directory was changed"

# An unmanaged directory whose content is exactly what would be installed is
# adopted -- marker written, nothing else changed -- instead of being a
# conflict. This is the Cloudflare plugin writing the same skill at the same
# upstream commit as our pin; a byte that differs is still a conflict.
rm -rf "$copy_home/.claude/skills/owned"
cp -R "$fixture/skills/owned" "$copy_home/.claude/skills/owned"
[[ ! -f "$copy_home/.claude/skills/owned/.llmctx-managed.json" ]] || fail "test setup: the copy is already marked"
# (The `local` conflict above is left in place on purpose, so every install
# from here on exits non-zero; the assertions read the output and the marker.)
out="$(HOME="$copy_home" "$fixture/bin/llmctx" skills install 2>&1 || true)"
grep -q "adopted: $copy_home/.claude/skills/owned" <<<"$out" || fail "an identical unmanaged directory was not adopted: $out"
grep -q "conflict: .*skills/owned" <<<"$out" && fail "an identical unmanaged directory was reported as a conflict"
jq -e '.managedBy == "jamesernet/llm-context"' "$copy_home/.claude/skills/owned/.llmctx-managed.json" >/dev/null ||
  fail "adopted directory has no marker"
rm -rf "$copy_home/.claude/skills/owned"
cp -R "$fixture/skills/owned" "$copy_home/.claude/skills/owned"
printf '%s\n' 'one byte more' >>"$copy_home/.claude/skills/owned/SKILL.md"
out="$(HOME="$copy_home" "$fixture/bin/llmctx" skills install 2>&1 || true)"
grep -q "conflict: $copy_home/.claude/skills/owned is not managed" <<<"$out" ||
  fail "an unmanaged directory that DIFFERS was not reported as a conflict: $out"
grep -q 'one byte more' "$copy_home/.claude/skills/owned/SKILL.md" || fail "a differing unmanaged directory was overwritten"
rm -rf "$copy_home/.claude/skills/owned"
HOME="$copy_home" "$fixture/bin/llmctx" skills install >/dev/null 2>&1 || true
[[ -f "$copy_home/.claude/skills/owned/.llmctx-managed.json" ]] || fail "reinstall after the conflict did not restore the managed copy"

dev_home="$tmp/dev-home"
HOME="$dev_home" "$fixture/bin/llmctx" skills install --dev >/dev/null
for target in "$dev_home/.claude/skills" "$dev_home/.codex/skills"; do
  [[ -L "$target/owned" ]] || fail "development skill was not linked"
  [[ "$(readlink "$target/owned")" == "$fixture/skills/owned" ]] || fail "development link points to the wrong source"
done

if HOME="$dev_home" "$fixture/bin/llmctx" skills install --unknown >/dev/null 2>&1; then
  fail "unknown option was accepted"
fi

# --- bundles ----------------------------------------------------------------
#
# Narrowing must actually narrow, and must PRUNE what it drops — an install that
# only ever adds cannot reduce anything, which was the whole point.

bhome="$tmp/bundle-home"
rm -rf "$bhome" && mkdir -p "$bhome"

HOME="$bhome" "$SRC/bin/install-skills.sh" >/dev/null 2>&1 || fail "default install failed"
all_n="$(find "$bhome/.claude/skills" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
[ "$all_n" -gt 0 ] || fail "default install produced no skills"

HOME="$bhome" "$SRC/bin/install-skills.sh" --bundle core >/dev/null 2>&1 || fail "--bundle core failed"
core_n="$(find "$bhome/.claude/skills" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
[ "$core_n" -lt "$all_n" ] || fail "core bundle did not narrow the installed set ($core_n vs $all_n)"
[ -d "$bhome/.claude/skills/codebase-design" ] || fail "core bundle is missing codebase-design"
[ -d "$bhome/.claude/skills/kyc-aml-review" ] && fail "core bundle installed a fintech skill"

# Inclusion is transitive: website pulls in core.
HOME="$bhome" "$SRC/bin/install-skills.sh" --bundle website >/dev/null 2>&1 || fail "--bundle website failed"
[ -d "$bhome/.claude/skills/product-ux-review" ] || fail "website bundle is missing product-ux-review"
[ -d "$bhome/.claude/skills/codebase-design" ] || fail "website bundle did not include core transitively"

# Comma-separated bundles union rather than being read as one name.
HOME="$bhome" "$SRC/bin/install-skills.sh" --bundle webapp,fintech >/dev/null 2>&1 || fail "comma-separated bundles failed"
[ -d "$bhome/.claude/skills/kyc-aml-review" ] || fail "second bundle in the list was not applied"
[ -d "$bhome/.claude/skills/product-ux-review" ] || fail "first bundle in the list was not applied"

# A typo must change nothing. Resolving an unknown name to the empty set would
# prune every installed skill.
before="$(find "$bhome/.claude/skills" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
if HOME="$bhome" "$SRC/bin/install-skills.sh" --bundle nope >/dev/null 2>&1; then
  fail "an unknown bundle was accepted"
fi
after="$(find "$bhome/.claude/skills" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
[ "$before" = "$after" ] || fail "an unknown bundle changed the installed set ($before -> $after)"
if HOME="$bhome" "$SRC/bin/install-skills.sh" --bundle core,nope >/dev/null 2>&1; then
  fail "an unknown bundle inside a list was accepted"
fi
[ "$before" = "$(find "$bhome/.claude/skills" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')" ] ||
  fail "a bad name in a bundle list still changed the installed set"

# Every bundle in the shipped file must resolve to at least one real skill.
while IFS= read -r b; do
  [ -n "$b" ] || continue
  HOME="$bhome" "$SRC/bin/install-skills.sh" --bundle "$b" >/dev/null 2>&1 ||
    fail "shipped bundle '$b' failed to install"
  [ "$(find "$bhome/.claude/skills" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')" -gt 0 ] ||
    fail "shipped bundle '$b' resolved to nothing"
done < <(grep -v '^#' "$SRC/skills/bundles.conf" | grep -v '^$' | cut -d'|' -f1 | sort -u)

# The converse of the check above: every shipped skill must resolve into at
# least one bundle, or it only ever installs under `all`.
while IFS= read -r skill; do
  [ -n "$skill" ] || continue
  grep -q "^[a-z0-9-]*|${skill}\$" "$SRC/skills/bundles.conf" ||
    fail "shipped skill '$skill' belongs to no bundle"
done < <(find "$SRC/skills" -mindepth 2 -maxdepth 2 -name SKILL.md -print |
  sed 's#/SKILL.md$##' | awk -F/ '{print $NF}' | sort -u)

# --- per-account bundles ------------------------------------------------------
# One machine runs accounts with different needs. A single global key would let
# a plain install re-apply one account's choice to every other account.
pahome="$tmp/per-account-home"
mkdir -p "$pahome"
acme_dir="$pahome/.claude-acme"
git config --global --add llmctx.claudeAccount "acme=$acme_dir"
git config --global llmctx.skillBundle core
git config --global llmctx.skillBundle.acme fintech

HOME="$pahome" "$SRC/bin/install-skills.sh" >/dev/null 2>&1 ||
  fail "per-account install failed"
[ -d "$pahome/.claude/skills/codebase-design" ] ||
  fail "default account did not get the global bundle"
[ -d "$pahome/.claude/skills/kyc-aml-review" ] &&
  fail "default account picked up the acme bundle"
[ -d "$acme_dir/skills/kyc-aml-review" ] ||
  fail "acme account did not get its own bundle"
[ -d "$acme_dir/skills/codebase-design" ] &&
  fail "acme account fell back to the global bundle"

# An explicit --bundle still wins for every target.
HOME="$pahome" "$SRC/bin/install-skills.sh" --bundle website >/dev/null 2>&1 ||
  fail "--bundle override failed"
[ -d "$acme_dir/skills/product-ux-review" ] ||
  fail "--bundle did not override the per-account key"

# A typo in one account's key must change nothing anywhere.
git config --global llmctx.skillBundle.acme nope
before="$(find "$pahome/.claude/skills" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
if HOME="$pahome" "$SRC/bin/install-skills.sh" >/dev/null 2>&1; then
  fail "an unknown per-account bundle was accepted"
fi
[ "$before" = "$(find "$pahome/.claude/skills" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')" ] ||
  fail "an unknown per-account bundle pruned another account"

git config --global --unset llmctx.skillBundle.acme
git config --global --unset llmctx.skillBundle
git config --global --unset-all llmctx.claudeAccount

echo "skill install tests: passed"
