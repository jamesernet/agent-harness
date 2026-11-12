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
#   llmctx_target_action_statements "<command text>"   (one statement per line, nothing removed)
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
# WHICH REPOSITORY, not which directory. `--git-dir=<x>/.git` names a
# repository, so the answer is `<x>` -- the directory CONTAINING it, because
# `rev-parse --show-toplevel` is fatal from inside a `.git` (measured), and
# that call is the first thing branch-policy.sh makes with this answer; the
# git dir itself would make it exit 0, which is the bypass this closes (#103).
# A git dir not named `.git` -- bare, or `--separate-git-dir` -- has no work
# tree to contain it, so the git dir is returned as-is and the callers'
# `--show-toplevel` fails as it would anyway.
#
# `--work-tree=<w>` on its own is NOT read, deliberately. Without `--git-dir`
# git still discovers the repository from the cwd and only takes the files
# from `<w>`, so the repository being acted on is unchanged -- and alongside
# `--git-dir` the git dir has already decided. Reading it would answer a
# question nobody asked ("where are the files") with the name of a variable
# the branch does not live in.
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

llmctx_target_strip_slashes() {
  local p="$1"
  while [[ "$p" == */ && "$p" != "/" ]]; do p="${p%/}"; done
  printf '%s\n' "$p"
}

# Resolve symlinks and `..` through the deepest ancestor that EXISTS, then
# re-append the part that does not yet (a new file's parent may be new).
#
# Any caller comparing two paths needs this, and comparing paths is what every
# consumer of this library does: `/var` and `/private/var` are the same
# directory on macOS, so a prefix test between an uncanonicalised path and a
# `git rev-parse --show-toplevel` result is wrong in whichever direction the
# symlink was not followed. That is not a hypothetical — it is the first thing
# that fails when you write a test with mktemp on a Mac.
llmctx_target_canonical() {
  local p="$1" rest="" dir
  p="$(llmctx_target_strip_slashes "$p")"
  dir="$p"
  while [[ ! -d "$dir" && "$dir" != "/" && -n "$dir" ]]; do
    rest="/$(basename "$dir")$rest"
    dir="$(dirname "$dir")"
  done
  if [[ -d "$dir" ]]; then
    dir="$(cd "$dir" 2>/dev/null && pwd -P)" || dir="$p"
    printf '%s\n' "$(llmctx_target_strip_slashes "$dir$rest")"
  else
    printf '%s\n' "$p"
  fi
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

# Statements for ACTION matching: the same separators, plus backticks, and
# NOTHING removed. llmctx_target_statements strips `$( )` and backticks because
# a `cd` inside a substitution cannot move the outer command — that is a fact
# about shell STATE. A `git push --force` inside one still pushes — that is a
# SIDE EFFECT, and the hook that judges actions must see it. The `(` in the
# separator set already starts a new statement at `$(`; the backtick is added
# so `\`git push --force\`` is seen the same way.
# A statement may also begin with a shell keyword or a brace that the matchers
# below would otherwise see as the verb: `if x; then git push --force; fi`,
# `for r in a; do rm -rf $r; done`, `{ git push --force; }`, `! rm -rf /`.
# Those are stripped from the front of each statement, repeatedly, so the
# verb is what follows them. Braces are not separators -- `${HOME}` must stay
# whole -- so only a LEADING brace is removed. BSD sed takes the label and the
# branch as separate expressions.
#
# A heredoc body is data, not statements: `cat > notes.md <<'EOF'` followed by
# a line reading `git push --force` writes a file. The body lines, up to the
# delimiter, are dropped before splitting; a `<<-` delimiter may be indented
# with tabs, as the shell allows.
llmctx_target_action_statements() {
  printf '%s\n' "$1" |
    awk '
      body { if ($0 == delim || (dash && sub(/^\t+/, "") && $0 == delim)) { body = 0 } ; next }
      { print }
      match($0, /<<-?[[:space:]]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/) {
        d = substr($0, RSTART, RLENGTH); dash = (d ~ /^<<-/)
        sub(/^<<-?[[:space:]]*["'"'"']?/, "", d); sub(/["'"'"']$/, "", d)
        delim = d; body = 1
      }' |
    tr ';&|()`' '\n\n\n\n\n\n' |
    sed -E -e ':a' -e 's/^[[:space:]]*([{}]|(then|do|else|elif|!)([[:space:]]+|$))//' -e 'ta'
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

# One global option's value, in either spelling git accepts: `--opt=value`
# or `--opt value`, anywhere among the other global options after `git`.
# Deliberately `[^[:space:]]+`: a quoted path containing a space truncates to
# a non-directory and every caller's own existence test then rejects it, which
# is "cannot tell" reached by a different road. Capturing it properly needs a
# tokenizer, and a guard that half-parses shell is wrong in both directions.
# The value of one git GLOBAL option, in either spelling git accepts
# (`--opt=value`, `--opt value`), from the last statement whose VERB is git.
#
# Two things it insists on, because without them a commit message sets the
# scope. The git word must be the statement's verb, behind at most the
# prefixes a shell allows -- so `echo git --git-dir=/x` is echo's business.
# And the option must come BEFORE the subcommand, which is where git's global
# options live -- so `git commit -m "use --git-dir=/evil/.git"` is a message.
# Scanning stops at the first word that is not an option or an option's value;
# that word is the subcommand.
#
# Deliberately whitespace-delimited: a quoted path containing a space
# truncates to a non-directory, every caller's own existence test rejects it,
# and that is "cannot tell" reached by a different road. Capturing it properly
# needs a tokenizer, and a guard that half-parses shell is wrong in both
# directions. Last statement wins, as the `cd` rule does, because that is what
# the shell does with a sequence.
llmctx_target_git_option() { # <command text> <long-option-name>
  llmctx_target_statements "$1" | awk -v opt="--$2" '
    function unquote(v) {
      gsub(/^["'"'"']|["'"'"']$/, "", v)
      return v
    }
    {
      i = 1
      # Prefixes the shell allows in front of a verb: assignments, and the
      # wrappers that take the real command as their argument.
      while (i <= NF && ($i ~ /^[A-Za-z_][A-Za-z0-9_]*=/ ||
                         $i ~ /^(sudo|doas|command|exec|nohup|nice|ionice|time|timeout|env)$/ ||
                         $i ~ /^-/)) i++
      if (i > NF) next
      if ($i != "git" && $i !~ /\/git$/) next
      for (j = i + 1; j <= NF; j++) {
        if (index($j, opt "=") == 1) { found = unquote(substr($j, length(opt) + 2)); break }
        if ($j == opt && j < NF) { found = unquote($(j + 1)); break }
        if ($j !~ /^-/) break                       # the subcommand: stop
        if ($j ~ /^-[Cc]$/ && j < NF) { j++; continue }   # a two-word option
        if ($j ~ /^--(git-dir|work-tree|namespace|exec-path|super-prefix)$/ && j < NF) { j++; continue }
      }
    }
    END { if (found != "") print found }'
}

# The repository a git dir belongs to: the directory containing a `.git`, and
# the git dir itself for a bare or separate one, which has no containing work
# tree. See the header on why the containing directory and not the git dir.
llmctx_target_repo_of_git_dir() { # <git dir>
  local d="$1"
  d="$(llmctx_target_strip_slashes "$d")"
  case "$d" in
    */.git) printf '%s\n' "${d%/.git}" ;;
    .git) printf '%s\n' "." ;;
    *) printf '%s\n' "$d" ;;
  esac
}

llmctx_target_from_command() {
  local cmd="$1" dir var assigned

  # `--git-dir` names the repository outright, and outranks everything: it
  # beats the GIT_DIR environment variable (measured: `GIT_DIR=a git
  # --git-dir=b rev-parse` answers for b), and it beats `-C`, which only
  # changes the directory the option is then read relative to.
  dir="$(llmctx_target_git_option "$cmd" "git-dir")"
  if [[ -n "$dir" ]]; then
    llmctx_target_repo_of_git_dir "$(llmctx_target_expand_home "$dir")"
    return 0
  fi

  # A leading `GIT_DIR=<d> git …` assignment says the same thing one step
  # lower, since the option above wins when both are present. Only an
  # assignment in front of a git VERB counts -- `git commit -m "GIT_DIR=x"`
  # is a message, and `GIT_DIR=x make` is not git's business.
  dir="$(llmctx_target_statements "$cmd" | awk '
    {
      i = 1; d = ""
      while (i <= NF && ($i ~ /^[A-Za-z_][A-Za-z0-9_]*=/ ||
                         $i ~ /^(sudo|doas|command|exec|nohup|nice|ionice|time|timeout|env)$/)) {
        if (index($i, "GIT_DIR=") == 1) d = substr($i, 9)
        i++
      }
      if (i <= NF && ($i == "git" || $i ~ /\/git$/) && d != "") {
        gsub(/^["'"'"']|["'"'"']$/, "", d)
        found = d
      }
    }
    END { if (found != "") print found }')"
  if [[ -n "$dir" ]]; then
    llmctx_target_repo_of_git_dir "$(llmctx_target_expand_home "$dir")"
    return 0
  fi

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
