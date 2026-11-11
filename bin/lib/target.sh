# shellcheck shell=bash
# Which directory does a shell command act on?
#
# Both Claude hooks have to answer this, and both used to answer it separately.
# The parsing was byte-identical in places and had diverged in one behaviour
# (see "THE ONE DIVERGENCE" below), while only one copy carried the record of
# the bugs that produced its current form. That record is now here, with the
# code it explains.
#
# Bash 3.2 (macOS) — no associative arrays, no `declare -g`.
#
# INTERFACE
#
#   llmctx_target_from_command "<command text>"
#   $LLMCTX_GIT_GLOBAL_OPTS_RE   (an ERE fragment, see below)
#
# Prints the directory the command names, or nothing when it cannot tell.
# "Cannot tell" is a first-class answer and the caller must handle it.
#
# What this does NOT decide, deliberately, because the two callers need
# different answers:
#
#   * whether the path exists. branch-policy.sh needs somewhere real for
#     `git -C` to stand and applies its own `-d` test; account-guard.sh
#     prefix-matches a path that may not exist yet and canonicalises instead.
#   * whether a relative path is resolved, and against what. A relative result
#     is returned as written; the caller resolves it against the payload cwd,
#     which is the only cwd either hook may trust.
#
# This is string work throughout. No eval, no shell parser. Where it cannot
# tell, it says so and the caller falls back — which is the safe direction for
# both hooks, since both fail open.

# The tilde is held in a variable: shellcheck reads a quoted literal `~` as a
# failed expansion (SC2088), but this matches a tilde someone typed, rather
# than asking the shell for $HOME.
llmctx_target_tilde="~"

# `cd ~/x` is written far more often than the expanded path. Expanding a
# leading `~/` keeps this to string work rather than eval.
# Global options git accepts between `git` and the subcommand: `-C <dir>`,
# `-c <k=v>`, the lone flags `-p` and `-P`, `--<long>`, `--<long>=<v>`, and a
# long option's separate value. An ERE fragment for the ACTION matchers in
# both hooks, kept beside the target resolver on purpose: `git -C <dir>` is the
# spelling this library resolves most carefully, and for months it was the one
# spelling the branch guard's matcher could not see (#79). Zero or more
# options, each ending in whitespace, so it slots between `git[[:space:]]+`
# and the subcommand. What follows it must be the whole subcommand word:
# anchor on whitespace or end, never `\b`, because `-` is a word boundary and
# `commit\b` matches `commit-graph` and `commit-tree`.
# shellcheck disable=SC2034  # consumed by the hooks that source this file
LLMCTX_GIT_GLOBAL_OPTS_RE='(-C[[:space:]]+[^[:space:]]+[[:space:]]+|-c[[:space:]]+[^[:space:]]+[[:space:]]+|-[pP][[:space:]]+|--[a-z][a-z-]*(=[^[:space:]]*)?[[:space:]]+([^-[:space:]][^[:space:]]*[[:space:]]+)?)*'

llmctx_target_expand_home() {
  case "$1" in
    "$llmctx_target_tilde") printf '%s\n' "$HOME" ;;
    "$llmctx_target_tilde"/*) printf '%s\n' "$HOME/${1#"$llmctx_target_tilde"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Command substitutions are removed FIRST. A `cd` inside `$( )` or backticks
# runs in a subshell whose directory never reaches the outer command, so
# honouring it would scope a guard to a directory the write never touches —
# `git commit -m "$(cd /elsewhere && pwd)"` must still be judged where the
# commit lands. One level is unwound, which is what gets written; anything
# deeper leaves a `cd` that fails the caller's checks and falls through.
#
# Separators then become newlines, which makes each statement a line and keeps
# this to `sed`: no eval, no parser.
#
# `sed -E`, not BRE. BSD sed — which is what macOS ships, and this repo
# supports macOS first — has no `\|` alternation in basic expressions, so a BRE
# form matched nothing here and silently fell through. It failed open, which is
# the safe direction, but it also meant the fix did nothing at all on the
# machine it was written on.
llmctx_target_statements() {
  printf '%s' "$1" |
    sed -E -e 's/\$\([^()]*\)//g' -e 's/`[^`]*`//g' |
    tr ';&|()' '\n\n\n\n\n'
}

# A plain variable assigned in the SAME command text. This is the dominant way
# an agent addresses a worktree — the path is long, so it goes in a variable
# first — and it defeated every earlier rule: the `cd` capture returns the
# literal `$WT`, which is not a directory, so the scope fell back to the
# session cwd. The result was a commit in a feature worktree judged against
# whatever the PRIMARY checkout had checked out. Under a worktree-per-session
# flow the primary checkout sits on the trunk by design, so that denied every
# commit from every worktree, and the message pointed at branching when the
# session had already branched.
#
# Still a lookup rather than an evaluation: the assignment is literally present
# in the text. Only a bare `$VAR` / `${VAR}` is honoured — a variable built
# from other variables, or set in an earlier tool call, is not visible here and
# correctly yields nothing. Assignments are read only at the start of a
# statement, so `--flag=x` is not mistaken for one. First wins, as the shell does.
llmctx_target_assigned_value() {
  local cmd="$1" var="$2"
  llmctx_target_statements "$cmd" |
    sed -E -n "s/^[[:space:]]*${var}=[\"']?([^\"']*[^\"' ])[\"']?[[:space:]]*\$/\1/p" | head -1
}

llmctx_target_from_command() {
  local cmd="$1" dir var assigned

  # `git -C <dir> …` states its own target, and outranks any `cd`.
  dir="$(printf '%s' "$cmd" |
    sed -n 's/.*git[[:space:]]\{1,\}-C[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p' | head -1)"
  if [[ -n "$dir" ]]; then
    llmctx_target_expand_home "$dir"
    return 0
  fi

  # Any `cd` that begins a STATEMENT counts, and the LAST one wins.
  #
  # `sed` reads line by line, so `$` is end-of-LINE: a `cd` terminated by a
  # newline in a multi-line script is the same statement as one terminated by
  # `&&`, since the commands after it run in that directory either way.
  # Requiring `&&` rejected the most ordinary shape a multi-line script has.
  #
  # Last-wins replaced a leading-only rule. That rule declined to follow a `cd`
  # behind a prefix on the grounds that half-parsing shell is wrong in both
  # directions — correct as a principle, but leading-only was not the
  # conservative end of it. Measured before the change:
  #
  #   cd <feature> && git commit                        ALLOW   correct
  #   lsof … | xargs kill; cd <feature> && git commit    DENY    false positive
  #   cd <feature> && cd <primary-on-main> && git commit ALLOW   REAL VIOLATION
  #
  # The third is the hole: the second `cd` is the one the shell honours, the
  # commit lands on the trunk, and the guard allowed it — the exact failure the
  # leading-only comment cited as its reason not to widen. Last-wins is what
  # the shell does for sequential statements, so it fixed the false positive
  # and closed the hole together.
  dir="$(llmctx_target_statements "$cmd" |
    sed -E -n "s/^[[:space:]]*cd[[:space:]]+[\"']?([^\"']*[^\"' ])[\"']?[[:space:]]*\$/\1/p" |
    tail -1)"
  [[ -n "$dir" ]] || return 0

  dir="$(llmctx_target_expand_home "$dir")"

  # THE ONE DIVERGENCE, now decided.
  #
  # `cd "$VAR"` where the assignment is not in this command text cannot be
  # resolved here. branch-policy.sh used to keep the literal `$VAR` and let its
  # `-d` test reject it, falling back to the session cwd. account-guard.sh kept
  # the literal too, but had no `-d` test, so it canonicalised `$VAR` — which
  # walks up to the nearest existing ancestor and could select a route the
  # command never named.
  #
  # Returning nothing is the conservative reading of both: an unresolvable
  # variable means "cannot tell", the caller falls back to the cwd it was given,
  # and no route is matched on the strength of a path nobody wrote. That makes
  # account-guard.sh strictly more careful than before and leaves
  # branch-policy.sh's effective behaviour unchanged.
  case "$dir" in
    '$'*)
      var="${dir#'$'}"
      var="${var#\{}"
      var="${var%\}}"
      assigned="$(llmctx_target_assigned_value "$cmd" "$var")"
      [[ -n "$assigned" ]] || return 0
      dir="$(llmctx_target_expand_home "$assigned")"
      ;;
  esac

  printf '%s\n' "$dir"
}
