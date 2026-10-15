#!/usr/bin/env bash
set -euo pipefail

# Generates local per-tool adapters from the canonical context files in this
# repo. Edit the source here, then run this script. Never edit generated output.
#
#   bin/build-adapters.sh                    regenerate local adapters
#   bin/build-adapters.sh --check            report drift and exit non-zero
#   bin/build-adapters.sh --account <name>   restrict to one Claude account
#
# Adapters (from global/):
#   <account>/CLAUDE.md   Claude Code — supports @import, so it references the files.
#   ~/.codex/AGENTS.md    Codex — no @import, so the files are concatenated inline.
#
# Claude output is built into EVERY registered account (bin/lib/accounts.sh),
# not just ~/.claude, because the alternative is what actually happened: a
# second account was created, the installer kept writing only to the first, and
# nothing reported a problem. Codex has no account concept, so its adapter is
# built once.
#
# Each account gets its OWN hooks/ rather than referencing the default
# account's. A cross-account path works until that directory is reset or moved,
# and then leaves a silently unwired safety hook — which is indistinguishable
# from a working one until the day it should have fired.
#
# Public website copies are a separate concern. Use
# bin/sync-published-context.sh so installing agent configuration never creates
# or edits unrelated repository paths.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
GLOBAL_DIR="$SRC/global"
# shellcheck source=bin/lib/accounts.sh
source "$SCRIPT_DIR/lib/accounts.sh"

check_only=0
account=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --check)
      check_only=1
      shift
      ;;
    --account)
      account="${2:-}"
      shift 2
      ;;
    --account=*)
      account="${1#--account=}"
      shift
      ;;
    *)
      echo "usage: build-adapters.sh [--check] [--account <name>]" >&2
      exit 2
      ;;
  esac
done

# global/ files loaded into every agent session, in order.
SHARED=(
  behavioral-guidelines.md
  communication-style.md
  handoff-and-briefs.md
)

# Per-account destinations. Empty until use_account() points them at one config
# directory; the run walks the registry and re-points them for each.
CLAUDE_MD=""
CLAUDE_SETTINGS_DEST=""
CLAUDE_HOOKS_DEST=""
POLICY_LIB_DEST=""
CLAUDE_CONFIG_PREFIX=""
CLAUDE_CONFIG_DISPLAY=""
CODEX_MD="$HOME/.codex/AGENTS.md"

# Versioned Claude Code settings (portable safety hooks). Source of truth for the
# keys it DECLARES; ~/.claude/settings.json is merged from it, not overwritten.
#
# The distinction matters. This file previously ended in `cp src dest`, which
# destroyed every local key the repo did not declare — `theme`, `statusLine`,
# anything Claude Code writes about its own UI. Those are machine-local
# preferences (a dark theme is right in an office and wrong in a bright hotel
# room), so versioning them is wrong, but silently deleting them on every
# rebuild is worse.
#
# So: repo values win for keys the repo declares; every other local key is left
# alone, and --check only compares the declared ones. The invariant is unchanged
# — this repo is still the single source of truth for what it manages — it just
# no longer claims ownership of things it never had an opinion about.
CLAUDE_SETTINGS_SRC="$SRC/claude/settings.json"

# PreToolUse hook scripts. Real scripts on disk, referenced by path from
# settings.json, rather than shell escaped into JSON: the previous inline form
# was unreadable, untestable, and invisible to both lint-skills.sh and the
# linter itself.
CLAUDE_HOOKS_SRC="$SRC/bin/claude-hooks"
POLICY_LIB_SRC="$SRC/bin/lib/policy.sh"

# Point every per-account destination at one config directory.
use_account() {
  local dir="$1"
  # The account NAME, for the identifying line render_claude emits. Optional so a
  # caller holding only a directory still works; the line is then omitted rather
  # than printed with an empty name.
  CLAUDE_ACCOUNT_NAME="${2:-}"
  CLAUDE_MD="$dir/CLAUDE.md"
  CLAUDE_SETTINGS_DEST="$dir/settings.json"
  CLAUDE_HOOKS_DEST="$dir/hooks"
  POLICY_LIB_DEST="$CLAUDE_HOOKS_DEST/llmctx-policy.sh"
  CLAUDE_CONFIG_PREFIX="$(llmctx_account_home_path "$dir")"
  # A LITERAL tilde: this one is prose inside the generated CLAUDE.md, read by a
  # human, not a path this script ever opens.
  # shellcheck disable=SC2088
  case "$dir" in
    "$HOME"/*) CLAUDE_CONFIG_DISPLAY="~/${dir#"$HOME"/}" ;;
    *) CLAUDE_CONFIG_DISPLAY="$dir" ;;
  esac
}

# jq's `*` is recursive for OBJECTS only. For every other type — arrays
# included — the right operand simply replaces the left. `hooks.PreToolUse` is
# an array, so `local * repo` silently discarded every locally-added hook entry
# and left only the one this repo declares.
#
# That is not theoretical. A machine-local account guard sat second in that
# array; the next `install.sh` would have deleted it, and `doctor` was already
# recommending exactly that command to clear the drift the extra entry caused.
# An unwired safety hook fails silently and looks identical to a working one.
#
# So hook arrays are merged by UNION on the hook SCRIPT NAME: this repo's
# entries are authoritative and come first, and any local entry naming a script
# this repo does not ship survives untouched. Same invariant as the top-level
# keys — the repo owns what it declares and nothing else — applied one level
# deeper.
#
# On the script NAME rather than the full path, because an account created by
# copying another carries the original's hook paths. Those entries are this
# repo's own, just pointing at the wrong account, and matching on the full path
# would leave the stale one in place beside the corrected one — the same guard
# wired twice. Matching on the basename re-points it instead.
#
# Not on the MATCHER, because two entries legitimately share one: that is how
# you attach two independent guards to the same tools.
HOOK_MERGE_JQ='
def entry_cmds: [.hooks[]? | .command // empty | split("/") | last];
. as $local
| ($local * $repo)
| if ($repo | has("hooks")) then
    .hooks = (
      reduce ($repo.hooks | keys_unsorted[]) as $e (($local.hooks // {});
        ([$repo.hooks[$e][]? | entry_cmds[]] | unique) as $rc
        | .[$e] = (($repo.hooks[$e] // [])
                   + [($local.hooks[$e][]?) | select((entry_cmds | any(IN($rc[]))) | not)]))
    )
  else . end
'

# The mirror image, for --check: the part of the live file this repo manages, so
# a local `theme` or a foreign hook entry never reports as drift.
HOOK_SUBSET_JQ='
def entry_cmds: [.hooks[]? | .command // empty | split("/") | last];
. as $local
| ($repo | keys) as $rk
| ($local | with_entries(select(.key as $k | $rk | index($k))))
| if ($repo | has("hooks")) then
    .hooks = (
      reduce ($repo.hooks | keys_unsorted[]) as $e ({};
        ([$repo.hooks[$e][]? | entry_cmds[]] | unique) as $rc
        | .[$e] = [($local.hooks[$e][]?) | select(entry_cmds | any(IN($rc[])))])
    )
  else . end
'

# claude/settings.json names its hook scripts through a {{CLAUDE_CONFIG_DIR}}
# placeholder, resolved per account here. A literal $HOME/.claude would point
# every account's settings at the DEFAULT account's hooks, which is a dependency
# nobody would notice until the day it broke.
render_settings_src() {
  jq --arg prefix "$CLAUDE_CONFIG_PREFIX" \
    'walk(if type == "string" then gsub("\\{\\{CLAUDE_CONFIG_DIR\\}\\}"; $prefix) else . end)' \
    "$CLAUDE_SETTINGS_SRC"
}

# The merged settings that SHOULD be on disk: local file as the base, repo
# values layered on top, hook arrays unioned rather than replaced.
render_settings() {
  local current="{}"
  [[ -f "$CLAUDE_SETTINGS_DEST" ]] && current="$(cat "$CLAUDE_SETTINGS_DEST")"
  printf '%s' "$current" |
    jq --argjson repo "$(render_settings_src)" "$HOOK_MERGE_JQ"
}

# The subset of the live file that this repo actually manages — used by --check
# so a local `theme` never reports as drift.
managed_subset() {
  [[ -f "$CLAUDE_SETTINGS_DEST" ]] || {
    echo '{}'
    return
  }
  jq --argjson repo "$(render_settings_src)" "$HOOK_SUBSET_JQ" \
    "$CLAUDE_SETTINGS_DEST"
}
GEN_NOTE="GENERATED by jamesernet/agent-harness/bin/build-adapters.sh — edit the source files in agent-harness, not here."

die() {
  echo "error: $*" >&2
  exit 1
}

# Fail before touching anything if an input is missing or empty. Cheaper to
# catch here than to discover a half-rendered adapter later.
preflight_sources() {
  local f
  for f in "${SHARED[@]}"; do
    [[ -f "$GLOBAL_DIR/$f" ]] || die "missing source: $GLOBAL_DIR/$f"
    [[ -s "$GLOBAL_DIR/$f" ]] || die "empty source: $GLOBAL_DIR/$f"
  done
}

# Render to a temp file, sanity-check it, then move it into place.
#
# `render_x > "$dest"` truncates $dest the moment the redirect opens — BEFORE
# the renderer runs. So a missing global/ file, a full disk or a Ctrl-C left the
# adapter truncated, and because the missing content is simply absent rather
# than malformed, nothing downstream noticed: you would keep working against
# silently reduced global instructions. Verified: a render whose middle `cat`
# failed produced a 14-byte file containing only the header and footer, and
# still exited 0.
#
# mv within the same filesystem is atomic, so the old file survives intact if
# anything above fails. $require is a regex that must appear in the output —
# non-empty alone is too weak, since a partial render is non-empty by definition.
install_rendered() {
  local renderer="$1" dest="$2" require="$3" min_bytes="${4:-1}"
  local dest_dir tmp size
  dest_dir="$(dirname "$dest")"
  mkdir -p "$dest_dir"
  # Atomic rename requires source and destination to be on the same filesystem.
  # /tmp is commonly a separate filesystem on Linux, so stage beside the target.
  tmp="$(mktemp "$dest_dir/.llmctx-adapter.XXXXXX")"
  # shellcheck disable=SC2064  # expand $tmp now, not at trap time
  trap "rm -f '$tmp'" RETURN

  "$renderer" >"$tmp" || die "$renderer failed; $dest left unchanged"

  # Three independent checks, because each alone has proven too weak:
  #   size>0    a truncating redirect leaves an empty file
  #   regex     a partial render is non-empty by definition
  #   min_bytes a partial render can still contain the regex, if the marker
  #             comes from a later line than the content that went missing
  size="$(wc -c <"$tmp" | tr -d ' ')"
  [[ "$size" -gt 0 ]] || die "$renderer produced an empty file; $dest left unchanged"
  grep -qE "$require" "$tmp" ||
    die "$renderer output is missing /$require/ — partial render; $dest left unchanged"
  [[ "$size" -ge "$min_bytes" ]] ||
    die "$renderer output is ${size}B, expected >=${min_bytes}B — partial render; $dest left unchanged"

  mv "$tmp" "$dest"
  echo "built: $dest"
}

# Codex inlines every shared file, so its adapter cannot legitimately be smaller
# than their combined size. Gives a concrete floor rather than a guessed one.
shared_bytes() {
  local total=0 f size
  for f in "${SHARED[@]}"; do
    size="$(wc -c <"$GLOBAL_DIR/$f" | tr -d ' ')"
    total=$((total + size))
  done
  echo "$total"
}

render_claude() {
  echo "# CLAUDE.md — Global Defaults"
  echo
  echo "<!-- $GEN_NOTE -->"
  echo
  for f in "${SHARED[@]}"; do echo "@$GLOBAL_DIR/$f"; done
  echo
  # WHICH ACCOUNT THIS IS. Claude Code loads ~/.claude/CLAUDE.md in addition to the
  # one for the active CLAUDE_CONFIG_DIR, so in a non-default account's session TWO
  # of these files sit in context at once. They come from one template and differ
  # only in the paths they name, which made the difference invisible and the hook
  # path a coin flip: an agent asked to inspect the branch guard had even odds of
  # reading, and editing, the inactive copy and reporting success.
  if [[ -n "$CLAUDE_ACCOUNT_NAME" ]]; then
    echo "This file belongs to the **\`$CLAUDE_ACCOUNT_NAME\`** Claude account (\`$CLAUDE_CONFIG_DISPLAY\`). More than one account's \`CLAUDE.md\` can be loaded in a single session, and they differ only in the paths they name. **Where two disagree, the one naming your active \`CLAUDE_CONFIG_DIR\` wins** — \`/status\` names the live account."
    echo
  fi
  echo "## Claude Code specifics"
  echo
  echo "The \"branch before you build\" rule has a global \`PreToolUse\` hook behind it (\`$CLAUDE_CONFIG_DISPLAY/hooks/branch-policy.sh\`). How hard it pushes is per-repo, via \`git config llmctx.branchPolicy\`:"
  echo
  echo "| policy | behaviour |"
  echo "|---|---|"
  echo "| \`off\` | no check |"
  echo "| \`remind\` | reminds once per session, then allows — **default** |"
  echo "| \`ask\` | confirms every edit/commit on a protected branch |"
  echo "| \`deny\` | blocks outright — default for committed client profiles |"
  echo
  echo "Repo-local config beats global, so the strict setting lives in the repos that warrant it. The hook is a backstop; the rule in the guidelines is the intent, and it applies even where the policy is \`off\`."
}

render_codex() {
  echo "# AGENTS.md — Global Defaults"
  echo
  echo "<!-- $GEN_NOTE Codex has no @import, so the shared files are concatenated below. -->"
  echo
  # `|| return 1` is load-bearing. install_rendered calls this as
  # `render_codex >tmp || die`, and the `||` disables errexit for the whole
  # call — so without an explicit check a failed cat (unreadable file, I/O
  # error) is swallowed, the function returns 0 from its last echo, and the
  # adapter is written MISSING that file's content. Verified: chmod 000 on one
  # global/ file produced a complete-looking 6.6KB AGENTS.md with a whole
  # section absent, and exit status 0.
  for f in "${SHARED[@]}"; do
    cat "$GLOBAL_DIR/$f" || return 1
    echo
    echo "---"
    echo
  done
  echo "## Codex specifics"
  echo
  echo "There is no \`PreToolUse\` hook in Codex. The \"branch before you build\" rule is prose-only here — rely on remote branch protection or a repo pre-commit hook as the backstop."
}

# A LINKED WORKTREE MUST NOT INSTALL. $SRC is this script's own parent, and the
# Claude adapter references the global files BY PATH rather than inlining them —
# so running from a worktree writes `@import <worktree>/global/...` into every
# registered account's CLAUDE.md. That path dies with the worktree, and a missing
# @import target is SILENT: every session afterwards loses the global rules with
# no error, and nothing connects the loss to the cause. Observed 2026-09-03.
#
# Refusing rather than silently resolving to the primary checkout: someone who
# runs this from a worktree means to install THAT branch's adapters, and quietly
# installing different content is the same class of surprise one level down.
# LLMCTX_ALLOW_WORKTREE_INSTALL=1|true|yes is the deliberate override; --check is
# exempt because it writes nothing, and so is the test suite, which installs into
# a throwaway $HOME.
refuse_worktree_install() {
  local git_dir common_dir primary override

  # The two paths are resolved with git's repository-local variables CLEARED.
  # `rev-parse` honours GIT_DIR and GIT_COMMON_DIR from the environment over
  # discovery from the cwd, and git exports them to every hook it runs -- so
  # left set, both resolve to the primary, they compare equal, and this guard
  # waves through the install it exists to block. That is not hypothetical: it
  # covers any run under a hook, `git rebase -x`, or `git bisect run`.
  # tests/run.sh clears the same variables before creating repositories, for the
  # same reason; this is that idiom, scoped to one subshell.
  {
    read -r git_dir
    read -r common_dir
  } < <(
    while IFS= read -r variable; do
      unset "$variable"
    done < <(git rev-parse --local-env-vars)
    cd "$SRC" || exit 0
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
    (cd "$(git rev-parse --git-dir)" && pwd) || exit 0
    (cd "$(git rev-parse --git-common-dir)" && pwd) || exit 0
  )
  [[ -n "${git_dir:-}" && -n "${common_dir:-}" ]] || return 0
  [[ "$git_dir" != "$common_dir" ]] || return 0

  # Tested by VALUE, not emptiness. `-z` made every non-empty value opt in, so
  # LLMCTX_ALLOW_WORKTREE_INSTALL=0 enabled precisely what a reader expects it to
  # disable, and the warning read as though they had asked for it.
  override="$(printf '%s' "${LLMCTX_ALLOW_WORKTREE_INSTALL:-}" | tr '[:upper:]' '[:lower:]')"
  case "$override" in
    1 | true | yes)
      echo "warning: installing adapters from a linked worktree (LLMCTX_ALLOW_WORKTREE_INSTALL=$LLMCTX_ALLOW_WORKTREE_INSTALL)." >&2
      echo "         every account's CLAUDE.md will @import from $SRC, which dies with this worktree." >&2
      return 0
      ;;
    "" | 0 | false | no) ;;
    *)
      echo "error: LLMCTX_ALLOW_WORKTREE_INSTALL must be 1/true/yes or 0/false/no," >&2
      echo "       got: $LLMCTX_ALLOW_WORKTREE_INSTALL" >&2
      exit 2
      ;;
  esac
  primary="$(dirname "$common_dir")"
  cat >&2 <<EOF
error: refusing to install adapters from a linked worktree.

  running from: $SRC
  primary:      $primary

The Claude adapter @imports the global files by path, so installing from here
would point every account's CLAUDE.md at this worktree. Remove the worktree and
those imports resolve to nothing — silently, with no error in any later session.

Run it from the primary checkout instead:

  git -C "$primary" status        # confirm it is on the branch you want
  "$primary/bin/build-adapters.sh"

To install from here anyway, set LLMCTX_ALLOW_WORKTREE_INSTALL=1.
EOF
  exit 1
}

# Resolved once, before anything is written. A malformed registry must stop the
# run rather than quietly reduce it to the accounts that happened to parse.
accounts="$(llmctx_accounts_selected "$account")" || exit 1

[[ "$check_only" -eq 1 ]] || refuse_worktree_install

if [[ "$check_only" -eq 1 ]]; then
  drift=0
  while IFS=$'\t' read -r account_name account_dir; do
    [[ -n "$account_name" ]] || continue
    use_account "$account_dir" "$account_name"
    diff <(render_claude) "$CLAUDE_MD" >/dev/null 2>&1 || {
      echo "drift: $CLAUDE_MD"
      drift=1
    }
    # Compare only the keys this repo declares. A local `theme` is not drift.
    diff <(render_settings_src | jq -S .) <(managed_subset | jq -S .) >/dev/null 2>&1 ||
      {
        echo "drift: $CLAUDE_SETTINGS_DEST (backport portable changes to claude/settings.json, or rebuild)"
        drift=1
      }
    for h in "$CLAUDE_HOOKS_SRC"/*.sh; do
      [[ -e "$h" ]] || continue
      diff "$h" "$CLAUDE_HOOKS_DEST/$(basename "$h")" >/dev/null 2>&1 ||
        {
          echo "drift: $CLAUDE_HOOKS_DEST/$(basename "$h")"
          drift=1
        }
    done
    diff "$POLICY_LIB_SRC" "$POLICY_LIB_DEST" >/dev/null 2>&1 || {
      echo "drift: $POLICY_LIB_DEST"
      drift=1
    }
  done <<<"$accounts"

  # Codex is not a Claude account, so a run narrowed to one has nothing to say
  # about it either way.
  if [[ -z "$account" ]]; then
    diff <(render_codex) "$CODEX_MD" >/dev/null 2>&1 || {
      echo "drift: $CODEX_MD"
      drift=1
    }
  fi

  if [[ "$drift" -ne 0 ]]; then
    echo "local adapters out of sync. run bin/build-adapters.sh to fix." >&2
    exit 1
  fi
  echo "all local adapters in sync."
  exit 0
fi

preflight_sources

while IFS=$'\t' read -r account_name account_dir; do
  [[ -n "$account_name" ]] || continue
  use_account "$account_dir" "$account_name"
  echo "account: $account_name -> $account_dir"
  install_rendered render_claude "$CLAUDE_MD" '^@'
  mkdir -p "$CLAUDE_HOOKS_DEST"
  for h in "$CLAUDE_HOOKS_SRC"/*.sh; do
    [[ -e "$h" ]] || continue
    install -m 0755 "$h" "$CLAUDE_HOOKS_DEST/$(basename "$h")"
    echo "built: $CLAUDE_HOOKS_DEST/$(basename "$h")"
  done
  install -m 0644 "$POLICY_LIB_SRC" "$POLICY_LIB_DEST"
  echo "built: $POLICY_LIB_DEST"

  # Merge, never clobber — see the comment at CLAUDE_SETTINGS_SRC. Written via a
  # temp file so an interrupted or failed jq cannot leave a truncated
  # settings.json behind, which would take Claude Code's configuration down
  # with it.
  mkdir -p "$(dirname "$CLAUDE_SETTINGS_DEST")"
  settings_dir="$(dirname "$CLAUDE_SETTINGS_DEST")"
  # Keep the temporary file beside the destination so mv is an atomic rename
  # even when /tmp and $HOME are different filesystems.
  settings_tmp="$(mktemp "$settings_dir/.llmctx-settings.XXXXXX")"
  trap 'rm -f "$settings_tmp"' EXIT
  render_settings >"$settings_tmp"
  mv "$settings_tmp" "$CLAUDE_SETTINGS_DEST"
  trap - EXIT
  echo "built: $CLAUDE_SETTINGS_DEST (merged; local keys preserved)"
done <<<"$accounts"

if [[ -z "$account" ]]; then
  install_rendered render_codex "$CODEX_MD" '^## Codex specifics' "$(shared_bytes)"
fi
