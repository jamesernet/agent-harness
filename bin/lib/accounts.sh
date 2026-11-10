# shellcheck shell=bash
# Provider accounts: one config directory per login.
#
# Claude Code keys its credential store by CLAUDE_CONFIG_DIR, so a second
# directory is a second, fully independent login rather than a swapped token.
# That is how one machine works across two organisations while keeping
# connectors and Remote Control working in both.
#
# NOT a repository policy profile. `llmctx explain profile` answers
# personal|client and describes a REPOSITORY; an account describes which Claude
# login a session runs on. Different axis, deliberately different word.
#
# The registry is machine state, not repository state, so it lives in global Git
# config beside llmctx.skillBundle:
#
#   git config --global --add llmctx.claudeAccount acme=~/.claude-acme
#   git config --global --add llmctx.codexAccount acme=~/.codex-acme
#
# $HOME/.claude and $HOME/.codex are always installed into, as `default`,
# registered or not.
# Registration is purely additive. A list that could omit the primary would
# reintroduce the failure this exists to fix: an install that silently skips a
# config directory and reports success.
#
# This file also owns resolution of the `@import` targets inside an account's
# generated CLAUDE.md, because that is the same subject matter — an account's
# config directory and the path forms it is written in — and the tilde
# expansion the resolver needs already lives here.

LLMCTX_ACCOUNT_KEY="llmctx.claudeAccount"
LLMCTX_ACCOUNT_DEFAULT_NAME="default"

llmctx_account_validate_provider() {
  case "$1" in
    claude | codex) ;;
    *)
      echo "error: provider '$1' must be claude or codex" >&2
      return 1
      ;;
  esac
}

llmctx_account_key() {
  local provider="${1:-claude}"
  llmctx_account_validate_provider "$provider" || return 1
  case "$provider" in
    claude) printf '%s\n' "$LLMCTX_ACCOUNT_KEY" ;;
    codex) printf '%s\n' "llmctx.codexAccount" ;;
  esac
}

llmctx_account_default_dir() {
  local provider="${1:-claude}"
  llmctx_account_validate_provider "$provider" || return 1
  case "$provider" in
    claude) printf '%s\n' "$HOME/.claude" ;;
    codex) printf '%s\n' "$HOME/.codex" ;;
  esac
}

# Absolute, `~` expanded, no trailing slash. The directory need not exist yet —
# installing is what creates it.
llmctx_account_expand_dir() {
  local dir="$1"
  # shellcheck disable=SC2088  # matching a LITERAL tilde is the point here
  case "$dir" in
    '~') dir="$HOME" ;;
    '~/'*) dir="$HOME/${dir#'~/'}" ;;
  esac
  while [[ "$dir" == */ && "$dir" != / ]]; do dir="${dir%/}"; done
  printf '%s\n' "$dir"
}

llmctx_account_validate_name() {
  local name="$1" provider="${2:-claude}" default_dir
  default_dir="$(llmctx_account_default_dir "$provider")" || return 1
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
    echo "error: account name '$name' must be lowercase letters, digits and hyphens" >&2
    return 1
  }
  [[ "$name" != "$LLMCTX_ACCOUNT_DEFAULT_NAME" ]] || {
    echo "error: '$LLMCTX_ACCOUNT_DEFAULT_NAME' is reserved for $default_dir" >&2
    return 1
  }
}

# Prints "<name>\t<dir>", `default` first. A malformed or colliding entry is a
# hard error rather than a skipped line: silently dropping one would install
# into fewer directories than asked for and still exit 0, which is the exact
# shape of the bug that made accounts necessary.
llmctx_accounts() {
  local provider="${1:-claude}" key entry name dir seen_names seen_dirs default_dir
  key="$(llmctx_account_key "$provider")" || return 1
  default_dir="$(llmctx_account_default_dir "$provider")" || return 1
  printf '%s\t%s\n' "$LLMCTX_ACCOUNT_DEFAULT_NAME" "$default_dir"
  seen_names=" $LLMCTX_ACCOUNT_DEFAULT_NAME "
  seen_dirs="	$default_dir	"

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    [[ "$entry" == *=* ]] || {
      echo "error: $key entry '$entry' is not <name>=<dir>" >&2
      return 1
    }
    name="${entry%%=*}"
    dir="$(llmctx_account_expand_dir "${entry#*=}")"
    llmctx_account_validate_name "$name" "$provider" || return 1
    [[ "$dir" == /* ]] || {
      echo "error: account '$name' directory '$dir' is not absolute" >&2
      return 1
    }
    case "$seen_names" in
      *" $name "*)
        echo "error: account '$name' is registered more than once" >&2
        return 1
        ;;
    esac
    # Two names for one directory would install twice and prune each other's
    # work on the second pass.
    case "$seen_dirs" in
      *"	$dir	"*)
        echo "error: '$dir' is already registered under another account" >&2
        return 1
        ;;
    esac
    seen_names="$seen_names$name "
    seen_dirs="$seen_dirs$dir	"
    printf '%s\t%s\n' "$name" "$dir"
  done < <(git config --global --get-all "$key" 2>/dev/null || true)
}

# The single account named, or every account when no name is given.
llmctx_accounts_selected() {
  local want="${1:-}" provider="${2:-claude}" all line
  all="$(llmctx_accounts "$provider")" || return 1
  [[ -n "$want" ]] || {
    printf '%s\n' "$all"
    return 0
  }
  while IFS= read -r line; do
    [[ "${line%%	*}" == "$want" ]] || continue
    printf '%s\n' "$line"
    return 0
  done <<<"$all"
  echo "error: unknown account '$want'" >&2
  echo "known: $(printf '%s\n' "$all" | cut -f1 | tr '\n' ' ')" >&2
  return 1
}

# A hook command path for an account, written $HOME-relative when it sits under
# $HOME so the generated settings stay portable between machines — Claude Code
# expands $HOME itself.
llmctx_account_home_path() {
  local dir="$1"
  case "$dir" in
    "$HOME") printf '%s\n' '$HOME' ;;
    "$HOME"/*) printf '$HOME/%s\n' "${dir#"$HOME"/}" ;;
    *) printf '%s\n' "$dir" ;;
  esac
}

# Direct `@import` targets in an account's CLAUDE.md that will not resolve when
# Claude Code reads it. An unresolved target produces NO error: the session
# simply runs without those rules, and nothing connects the loss to its cause.
#
# This is narrower than it looks, and the narrowness is the point. The paths
# render_claude writes are derived from the RUNNING script's own location, so a
# moved checkout, a pruned worktree or a hand edit all make the installed file
# differ from a fresh render and are already caught as adapter drift. What is
# byte-identical to a correct render and still broken is a global/ source that
# has been deleted, made unreadable or left dangling while the checkout sits
# where the installed file says it does — render_claude writes those paths
# without ever reading them. The other half of the value is diagnostic: drift
# says "missing or stale", this says which path is dead.
#
# One level only. A target may import further files, and walking the whole graph
# needs cycle detection for a case this repository does not generate — every
# global/*.md is import-free. Callers say "direct" rather than imply
# completeness.
#
# Prints one line per import, "<status>\t<lineno>\t<raw-target>\t<resolved-path>",
# status being ok, missing, unreadable or unsupported. Every import is reported
# rather than only the broken ones, so a caller can say how many resolve without
# parsing the file a second time. Exits 0 even with findings, because both
# callers run under `set -euo pipefail` and read this through a command
# substitution, where a non-zero return would abort the script: findings are
# data, not status. Exits 2, printing nothing, when the file itself cannot be
# read.
llmctx_unresolved_imports() {
  local file="$1" base line lineno=0 target resolved fenced=0 probe partial

  [[ -f "$file" && -r "$file" ]] || return 2
  base="$(dirname "$file")"

  # Redirected rather than piped: a pipeline runs the loop in a subshell and
  # loses $lineno. The `|| [[ -n "$line" ]]` keeps a final line with no
  # trailing newline, which a hand-edited file routinely has.
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))

    # A fenced block is documentation. The generated adapter has none, but this
    # also reads hand-edited files, where an example `@path` inside a fence must
    # not read as a broken import.
    case "$line" in '```'*) fenced=$((1 - fenced)) ;; esac
    [[ "$fenced" -eq 0 ]] || continue

    # Whole-line imports only, matching what render_claude emits. An inline
    # mid-sentence `@` would turn every prose mention into a finding.
    case "$line" in '@'?*) ;; *) continue ;; esac

    target="${line#@}"
    # Trailing whitespace, and the CR of a file edited on Windows, are not path.
    target="${target%"${target##*[![:space:]$'\r']}"}"
    [[ -n "$target" ]] || continue

    # Reported, not judged. Claude Code does not expand shell variables, so such
    # a line is probably already broken — but calling it missing would mean
    # printing a path we invented by expanding $HOME ourselves, which is a
    # different file from the one the resolver looks for, and the one-line
    # remediation is wrong for a hand edit. A tab would also break this
    # function's own output format. The generated adapter emits neither.
    #
    # Whitespace is deliberately NOT pre-judged here. A space is an ordinary
    # character in an already-literal path — `[[ -f "/My Dir/x.md" ]]` resolves
    # it with nothing invented — and treating it as unsupported made EVERY
    # import unsupported on a checkout whose path contains a space, which
    # reported PASS while checking nothing at all. Ambiguity is decided below,
    # by whether the literal target resolves.
    case "$target" in
      '$HOME'* | '${HOME}'* | *$'\t'*)
        printf 'unsupported\t%s\t%s\t\n' "$lineno" "$target"
        continue
        ;;
    esac

    # `~` IS expanded by Claude Code, and this file already owns that expansion.
    # shellcheck disable=SC2088  # matching a LITERAL tilde is the point here
    case "$target" in
      '~' | '~/'*) resolved="$(llmctx_account_expand_dir "$target")" ;;
      /*) resolved="$target" ;;
      *) resolved="$base/$target" ;;
    esac

    # -f rather than -e: a directory is not importable and a dangling symlink
    # correctly fails. Neither needs canonicalising — the kernel resolves `..`,
    # `.` and symlinks here, and realpath is absent on stock macOS.
    if [[ -f "$resolved" ]]; then
      if [[ -r "$resolved" ]]; then
        printf 'ok\t%s\t%s\t%s\n' "$lineno" "$target" "$resolved"
      else
        printf 'unreadable\t%s\t%s\t%s\n' "$lineno" "$target" "$resolved"
      fi
    else
      # Resolution failed. A whitespace-bearing target is ambiguous -- in
      # `@/path/file.md and then some prose` there is no way to know where the
      # path ends -- but ambiguous is not the same as absent. So try each
      # whitespace boundary: if some prefix IS a file, a real import exists
      # under one reading and only the extent is unclear, which is a skip. If
      # no prefix resolves, nothing is there under ANY reading, and that is
      # missing however you cut the line. The generated adapter writes the whole
      # line as the path, so its dead targets land in `missing` where they
      # belong rather than hiding in a skip.
      case "$target" in
        *[[:space:]]*)
          probe="$target"
          partial=""
          while [[ "$probe" == *[[:space:]]* ]]; do
            probe="${probe%[[:space:]]*}"
            [[ -f "$probe" ]] || continue
            partial="$probe"
            break
          done
          if [[ -n "$partial" ]]; then
            printf 'unsupported\t%s\t%s\t\n' "$lineno" "$target"
          else
            printf 'missing\t%s\t%s\t%s\n' "$lineno" "$target" "$resolved"
          fi
          ;;
        *) printf 'missing\t%s\t%s\t%s\n' "$lineno" "$target" "$resolved" ;;
      esac
    fi
  done <"$file"
}
