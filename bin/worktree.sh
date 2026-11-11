#!/usr/bin/env bash
set -euo pipefail

# Sibling worktrees for parallel agent sessions: one worktree per brief/issue,
# one Claude Code / Codex session per worktree, no branch-switching collisions.
#
#   worktree.sh new <branch> [start-point]   create <repo>-worktrees/<slug> for <branch>
#                                            (branch is created from start-point,
#                                            default HEAD, if it doesn't exist)
#   worktree.sh ls                           list this repo's worktrees
#   worktree.sh rm <branch>                  remove the worktree (branch is kept)
#   worktree.sh path <branch>                print the worktree path and exit
#   worktree.sh status [--json]              report every worktree, and every branch
#                                            with commits not yet on a protected
#                                            branch; reads only, changes nothing
#
# `path` exists so a shell wrapper can cd into a new worktree without
# recomputing the layout. A subprocess cannot change its parent's directory, so
# `new` can only ever tell you where it put things — see the `wt` function in
# workstation's config/zsh/functions.zsh, which uses this to do the cd for you.
# Keeping the computation here means the wrapper cannot drift from the script.
#
# Run from anywhere inside the target repo. Worktrees live NEXT TO the repo
# (…/<org>/<repo>-worktrees/<slug>), never inside it. Slug = branch with
# "/" flattened to "-". The pre-commit branch backstop lives in the main
# repo's .git and applies to every worktree automatically.
#
# `status` exists because finished work was invisible: three worktrees held
# tested, unpushed commits with no PR and no ticket, and a fourth held a whole
# skill staged and never committed, and nothing surfaced any of it until a
# cleanup pass happened to look. It answers "what is in flight here?" per
# worktree and per branch -- dirty state, commits not on a protected branch,
# upstream, the PR for the branch, and when that PR has merged, PROOF that it
# did: a squash merge gives the trunk a new commit with a different hash, so
# `git merge-base --is-ancestor <branch> main` says "not merged" about every
# correctly merged branch. The proof that works is the branch tip against the
# merged PR's headRefOid. It deletes nothing and suggests nothing; the line that
# matters is STRANDED -- commits, and no PR -- which is the state nothing else
# reports. A repository may list branch prefixes it has deliberately parked
# ("strandedExempt": ["backup/"] in .llmctx.json) so they do not occupy the
# output forever. The one network call is `gh pr list`, once; when gh is
# missing, fails or truncates, the PR column says `unknown` rather than `none`.

usage() {
  grep '^#   ' "$0" | sed 's/^#  //'
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cmd="${1:-}"

# Where the MAIN checkout is. Every subcommand lays worktrees out beside it, so
# it is resolved once, here, and asserted rather than inferred.
#
# --show-toplevel is the work-tree assertion. Outside a repository and in a bare
# one it is fatal, and a bare `var=$(...)` is the form `set -e` tracks, so the
# script stops with git's own message and exit 128 instead of printing a path it
# invented. It is also the right answer wherever the tree we stand in IS the
# main checkout: the primary, any subdirectory of it, and a submodule's own
# checkout -- where the shared git dir is <outer>/.git/modules/<sub>, and
# `dirname` of it would have put the worktrees INSIDE the superproject's .git.
#
# A linked worktree is the one place --show-toplevel is wrong, because it names
# the worktree we are standing in. It is recognised the way build-adapters.sh
# and this repo's pre-commit.local recognise it: the per-worktree git dir and
# the shared one are different directories. Only then is the main checkout
# taken from the shared .git, and only when that directory is literally named
# ".git". A linked worktree of a submodule, or of a repository made with
# --separate-git-dir, has no checkout at `dirname`, so it is refused by name.
#
# Physical paths (pwd -P) throughout: git records worktrees as /private/var on
# macOS while $TMPDIR says /var, and `git worktree remove` matches the recorded
# spelling. --show-toplevel is already realpath'd by git; --git-common-dir is
# RELATIVE from the primary (".git", "../.git"), hence the cd. Each cd is its
# own bare assignment so a failure is visible to set -e, not swallowed inside a
# larger string.
toplevel="$(git rev-parse --show-toplevel)"
git_dir="$(git rev-parse --git-dir)"
git_dir="$(cd "$git_dir" && pwd -P)"
common_dir="$(git rev-parse --git-common-dir)"
common_dir="$(cd "$common_dir" && pwd -P)"
if [[ "$git_dir" == "$common_dir" ]]; then
  root="$toplevel"
elif [[ "$(basename "$common_dir")" == .git ]]; then
  root="$(dirname "$common_dir")"
else
  cat >&2 <<EOF
worktree.sh: refusing to lay out worktrees from here.

  standing in:    $toplevel (a linked worktree)
  shared git dir: $common_dir

That directory is not a ".git" beside a checkout, so there is no main checkout
to put worktrees next to: this is a linked worktree of a submodule, or of a
repository created with --separate-git-dir. Run from the primary checkout.
EOF
  exit 1
fi
repo="$(basename "$root")"
wt_root="$(dirname "$root")/$repo-worktrees"

# Worktree parents were written "<repo>.worktrees" here while every repo-local
# helper and the rest of the estate used "<repo>-worktrees". The hyphen won, so
# new worktrees go there. The ones already on disk under the dot are still
# resolved for `path` and `rm`, which is what lets them drain instead of needing
# a migration: a worktree is short-lived, so the dot parents empty on their own.
wt_root_legacy="$(dirname "$root")/$repo.worktrees"

# Where an existing worktree for <slug> actually is: the hyphen, unless only the
# legacy dot copy is on disk.
wt_resolve() {
  if [ ! -e "$wt_root/$1" ] && [ -e "$wt_root_legacy/$1" ]; then
    echo "$wt_root_legacy/$1"
  else
    echo "$wt_root/$1"
  fi
}

# --- status -------------------------------------------------------------------

# Everything below reads; nothing writes outside the temp files it owns.

status_tmp() {
  mktemp "${TMPDIR:-/tmp}/llmctx-wt-status.XXXXXX"
}

# Which refs "landed" is measured against: every protected branch, local AND
# origin/, that actually exists. Local main is often behind origin/main, and
# `rev-list` is fatal on a ref that does not exist, so both are checked first.
status_protected_refs() {
  local p
  STATUS_PROTECTED=""
  STATUS_PROTECTED_REFS=()
  if llmctx_policy_resolve "$root"; then
    STATUS_PROTECTED="$LLMCTX_PROTECTED_BRANCHES"
  else
    echo "worktree.sh status: ${LLMCTX_POLICY_ERROR:-repository policy did not resolve}; measuring against main master" >&2
    STATUS_PROTECTED="main master"
  fi
  for p in $STATUS_PROTECTED; do
    if git -C "$root" show-ref --verify --quiet "refs/heads/$p"; then
      STATUS_PROTECTED_REFS+=("refs/heads/$p")
    fi
    if git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$p"; then
      STATUS_PROTECTED_REFS+=("refs/remotes/origin/$p")
    fi
  done
}

# One gh call for the whole report, and three ways it can fail, each named:
# gh-missing (not installed), gh-failed (offline, no remote, not logged in:
# first stderr line kept), gh-truncated (as many rows as the limit, so a
# branch missing from the list proves nothing). Under any of the three a
# branch with no row is `unknown`, never `none`.
status_fetch_prs() {
  local limit=200
  STATUS_PR_SOURCE="gh"
  STATUS_PR_ERROR=""
  printf '[]\n' >"$STATUS_PRS"
  if ! command -v gh >/dev/null 2>&1; then
    STATUS_PR_SOURCE="gh-missing"
  elif ! (cd "$root" && gh pr list --state all --limit "$limit" \
    --json headRefName,number,state,headRefOid >"$STATUS_PRS" 2>"$STATUS_GH_ERR"); then
    STATUS_PR_SOURCE="gh-failed"
    STATUS_PR_ERROR="$(head -n 1 "$STATUS_GH_ERR")"
    printf '[]\n' >"$STATUS_PRS"
  elif ! jq -e 'type == "array"' "$STATUS_PRS" >/dev/null 2>&1; then
    STATUS_PR_SOURCE="gh-failed"
    STATUS_PR_ERROR="gh pr list did not return a JSON array"
    printf '[]\n' >"$STATUS_PRS"
  elif [[ "$(jq length "$STATUS_PRS")" -ge "$limit" ]]; then
    STATUS_PR_SOURCE="gh-truncated"
  fi
}

# Porcelain v1: column 1 is the index, column 2 the work tree, "??" untracked.
# A file can be in both columns, so staged + unstaged may exceed the total.
# Counted in awk: `wc -l` pads with spaces on macOS.
status_dirty_counts() {
  local porcelain
  porcelain="$(git -C "$1" status --porcelain=v1 2>/dev/null || true)"
  read -r STATUS_DIRTY STATUS_STAGED STATUS_UNSTAGED STATUS_UNTRACKED < <(
    printf '%s\n' "$porcelain" | awk '
      NF == 0 { next }
      { total++ }
      /^\?\?/ { untracked++; next }
      substr($0, 1, 1) != " " { staged++ }
      substr($0, 2, 1) != " " { unstaged++ }
      END { print total + 0, staged + 0, unstaged + 0, untracked + 0 }'
  )
}

# Facts about one branch tip: commits past the protected refs, upstream state,
# the PR for the branch, and -- only when that PR has merged -- proof that this
# tip is what merged. Sets STATUS_F_* for the caller to emit.
status_branch_facts() {
  local branch="$1" tip="$2" up_short up_track counts pr_row prefix
  STATUS_F_AHEAD=null
  STATUS_F_UPSTREAM=none
  STATUS_F_UP_AHEAD=null
  STATUS_F_UP_BEHIND=null
  STATUS_F_PR_NUMBER=null
  STATUS_F_PR_STATE=unknown
  STATUS_F_PR_OID=""
  STATUS_F_PROOF=""
  STATUS_F_EXEMPT=false

  if [[ ${#STATUS_PROTECTED_REFS[@]} -gt 0 ]]; then
    STATUS_F_AHEAD="$(git -C "$root" rev-list --count "$tip" --not "${STATUS_PROTECTED_REFS[@]}")"
  fi

  [[ -n "$branch" ]] || return 0

  up_short="$(awk -F'\t' -v b="$branch" '$1 == b { print $3; exit }' "$STATUS_REFS")"
  up_track="$(awk -F'\t' -v b="$branch" '$1 == b { print $4; exit }' "$STATUS_REFS")"
  if [[ -z "$up_short" ]]; then
    STATUS_F_UPSTREAM=none
  elif [[ "$up_track" == "[gone]" ]]; then
    STATUS_F_UPSTREAM=gone
  else
    counts="$(git -C "$root" rev-list --left-right --count "$tip...$up_short" 2>/dev/null || printf '0\t0')"
    STATUS_F_UP_AHEAD="${counts%%[[:space:]]*}"
    STATUS_F_UP_BEHIND="${counts##*[[:space:]]}"
    if [[ "$STATUS_F_UP_AHEAD" -gt 0 && "$STATUS_F_UP_BEHIND" -gt 0 ]]; then
      STATUS_F_UPSTREAM=diverged
    elif [[ "$STATUS_F_UP_AHEAD" -gt 0 ]]; then
      STATUS_F_UPSTREAM=ahead
    elif [[ "$STATUS_F_UP_BEHIND" -gt 0 ]]; then
      STATUS_F_UPSTREAM=behind
    else
      STATUS_F_UPSTREAM=present
    fi
  fi

  # Several PRs can share a head branch over time; a merged one outranks an
  # open one, which outranks a closed one, because that is what the proof is for.
  pr_row="$(jq -c --arg b "$branch" '
    [.[] | select(.headRefName == $b)]
    | sort_by(if .state == "MERGED" then 0 elif .state == "OPEN" then 1 else 2 end)
    | .[0] // empty' "$STATUS_PRS")"
  if [[ -z "$pr_row" ]]; then
    if [[ "$STATUS_PR_SOURCE" == "gh" ]]; then
      STATUS_F_PR_STATE=none
    else
      STATUS_F_PR_STATE=unknown
    fi
  else
    STATUS_F_PR_NUMBER="$(jq -r '.number' <<<"$pr_row")"
    STATUS_F_PR_STATE="$(jq -r '.state' <<<"$pr_row")"
    STATUS_F_PR_OID="$(jq -r '.headRefOid // ""' <<<"$pr_row")"
  fi

  if [[ "$STATUS_F_PR_STATE" == "MERGED" && -n "$STATUS_F_PR_OID" ]]; then
    if [[ "$tip" == "$STATUS_F_PR_OID" ]]; then
      STATUS_F_PROOF=merged-exact
    elif ! git -C "$root" cat-file -e "${STATUS_F_PR_OID}^{commit}" 2>/dev/null; then
      # The merged head was never fetched here; --is-ancestor would exit 128,
      # and calling that "diverged" would be a lie.
      STATUS_F_PROOF=unverifiable
    elif git -C "$root" merge-base --is-ancestor "$tip" "$STATUS_F_PR_OID" 2>/dev/null; then
      STATUS_F_PROOF=merged-ancestor
    else
      STATUS_F_PROOF=diverged
    fi
  fi

  while IFS= read -r prefix; do
    [[ -n "$prefix" ]] || continue
    case "$branch" in
      "$prefix"*) STATUS_F_EXEMPT=true ;;
    esac
  done <<<"$STATUS_EXEMPT"
}

# First match wins, ordered by what would be lost if the row were trusted.
# DIRTY outranks MERGED on purpose: "verify the worktree is clean" is step one
# of the cleanup ritual, and a MERGED headline on a dirty tree reads as "safe
# to remove".
status_headline() {
  local ahead="$1" pr_state="$2" exempt="$3" dirty="$4" proof="$5"
  if [[ "$ahead" != null && "$ahead" -gt 0 && "$pr_state" == none && "$exempt" == false ]]; then
    echo STRANDED
  elif [[ "$ahead" != null && "$ahead" -gt 0 && "$pr_state" == unknown ]]; then
    echo UNKNOWN
  elif [[ "$dirty" != null && "$dirty" -gt 0 ]]; then
    echo DIRTY
  elif [[ "$proof" == diverged ]]; then
    echo DIVERGED
  elif [[ "$pr_state" == MERGED || "$pr_state" == OPEN || "$pr_state" == CLOSED ]]; then
    echo "$pr_state"
  else
    echo "-"
  fi
}

# One compact JSON object per row, appended; the report is assembled with jq -s.
# shellcheck disable=SC2154  # STATUS_F_* are set by status_branch_facts
status_emit_row() {
  local kind="$1" path="$2" branch="$3" head="$4" dirty="$5" staged="$6" unstaged="$7" untracked="$8" prunable="$9" locked="${10}" headline
  headline="$(status_headline "$STATUS_F_AHEAD" "$STATUS_F_PR_STATE" "$STATUS_F_EXEMPT" "$dirty" "$STATUS_F_PROOF")"
  jq -cn \
    --arg kind "$kind" --arg path "$path" --arg branch "$branch" --arg head "$head" \
    --argjson ahead "$STATUS_F_AHEAD" \
    --argjson dirty "$dirty" --argjson staged "$staged" --argjson unstaged "$unstaged" --argjson untracked "$untracked" \
    --argjson prunable "$prunable" --argjson locked "$locked" \
    --arg upstream "$STATUS_F_UPSTREAM" --argjson upstreamAhead "$STATUS_F_UP_AHEAD" --argjson upstreamBehind "$STATUS_F_UP_BEHIND" \
    --argjson prNumber "$STATUS_F_PR_NUMBER" --arg prState "$STATUS_F_PR_STATE" --arg prHeadRefOid "$STATUS_F_PR_OID" \
    --arg mergeProof "$STATUS_F_PROOF" --argjson exempt "$STATUS_F_EXEMPT" --arg headline "$headline" \
    '{kind: $kind,
      headline: $headline,
      branch: (if $branch == "" then null else $branch end),
      path: (if $path == "" then null else $path end),
      head: $head,
      ahead: $ahead,
      dirty: $dirty, staged: $staged, unstaged: $unstaged, untracked: $untracked,
      prunable: $prunable, locked: $locked,
      upstream: $upstream, upstreamAhead: $upstreamAhead, upstreamBehind: $upstreamBehind,
      prNumber: $prNumber, prState: $prState,
      prHeadRefOid: (if $prHeadRefOid == "" then null else $prHeadRefOid end),
      mergeProof: (if $mergeProof == "" then null else $mergeProof end),
      exempt: $exempt}' >>"$STATUS_ROWS"
}

status_report() {
  local json="$1" wt_path wt_head wt_branch wt_locked wt_prunable line
  local b_name b_sha protected_json

  command -v jq >/dev/null 2>&1 || {
    echo "worktree.sh status: jq is required" >&2
    exit 2
  }
  # shellcheck source=lib/policy.sh
  source "$SCRIPT_DIR/lib/policy.sh"

  STATUS_ROWS="$(status_tmp)"
  STATUS_PRS="$(status_tmp)"
  STATUS_GH_ERR="$(status_tmp)"
  STATUS_REFS="$(status_tmp)"
  STATUS_SEEN="$(status_tmp)"
  trap 'rm -f "$STATUS_ROWS" "$STATUS_PRS" "$STATUS_GH_ERR" "$STATUS_REFS" "$STATUS_SEEN"' EXIT

  status_protected_refs
  if [[ ${#STATUS_PROTECTED_REFS[@]} -eq 0 ]]; then
    echo "worktree.sh status: none of [$STATUS_PROTECTED] exists as a local or origin/ ref; commit counts are unknown" >&2
  fi
  # Policy is a property of the repository, read from the main checkout.
  # `// []` is right here (unlike repo-diff's scalar keys) because an absent
  # list and an empty list mean the same thing: nothing is exempt.
  STATUS_EXEMPT=""
  if [[ -f "$root/.llmctx.json" ]]; then
    STATUS_EXEMPT="$(jq -r '(.strandedExempt // []) | map(select(type == "string")) | .[]' "$root/.llmctx.json" 2>/dev/null || true)"
  fi
  status_fetch_prs
  git -C "$root" for-each-ref \
    --format='%(refname:short)%09%(objectname)%09%(upstream:short)%09%(upstream:track)' \
    refs/heads >"$STATUS_REFS"
  : >"$STATUS_SEEN"

  # Pass A: every worktree, including the primary. The trailing `echo` flushes
  # the last block even if git ever drops the blank line after it.
  wt_path="" wt_head="" wt_branch="" wt_locked=false wt_prunable=false
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) wt_path="${line#worktree }" ;;
      "HEAD "*) wt_head="${line#HEAD }" ;;
      "branch refs/heads/"*) wt_branch="${line#branch refs/heads/}" ;;
      detached) ;;
      locked*) wt_locked=true ;;
      prunable*) wt_prunable=true ;;
      "")
        if [[ -n "$wt_path" ]]; then
          if [[ -d "$wt_path" ]]; then
            status_dirty_counts "$wt_path"
          else
            wt_prunable=true
            STATUS_DIRTY=null STATUS_STAGED=null STATUS_UNSTAGED=null STATUS_UNTRACKED=null
          fi
          status_branch_facts "$wt_branch" "$wt_head"
          [[ -z "$wt_branch" ]] || printf '%s\n' "$wt_branch" >>"$STATUS_SEEN"
          status_emit_row worktree "$wt_path" "$wt_branch" "$wt_head" \
            "$STATUS_DIRTY" "$STATUS_STAGED" "$STATUS_UNSTAGED" "$STATUS_UNTRACKED" "$wt_prunable" "$wt_locked"
        fi
        wt_path="" wt_head="" wt_branch="" wt_locked=false wt_prunable=false
        ;;
    esac
  done < <(
    git -C "$root" worktree list --porcelain
    echo
  )

  # Pass B: branches with no worktree, listed only when they carry commits
  # not on a protected branch -- that is the state nothing else reports.
  # "Has a worktree" is decided by what pass A saw, not by for-each-ref's
  # %(worktreepath) atom, which is empty on at least one current git.
  while IFS=$'\t' read -r b_name b_sha _ _; do
    [[ -n "$b_name" ]] || continue
    if grep -Fxq -- "$b_name" "$STATUS_SEEN"; then continue; fi
    status_branch_facts "$b_name" "$b_sha"
    [[ "$STATUS_F_AHEAD" != null && "$STATUS_F_AHEAD" -gt 0 ]] || continue
    status_emit_row branch "" "$b_name" "$b_sha" null null null null false false
  done <"$STATUS_REFS"

  protected_json="$(printf '%s\n' $STATUS_PROTECTED | jq -R . | jq -s .)"
  if [[ "$json" -eq 1 ]]; then
    jq -s --arg repository "$root" --arg prSource "$STATUS_PR_SOURCE" --arg prError "$STATUS_PR_ERROR" \
      --argjson protectedBranches "$protected_json" \
      '{repository: $repository,
        protectedBranches: $protectedBranches,
        prSource: $prSource,
        prError: (if $prError == "" then null else $prError end),
        worktrees: [.[] | select(.kind == "worktree")],
        branches: [.[] | select(.kind == "branch")]}' "$STATUS_ROWS"
    return 0
  fi

  printf '%-9s %-40s %5s %5s %-9s %-13s %-16s %s\n' STATE BRANCH AHEAD DIRTY UPSTREAM PR PROOF PATH
  jq -r '[.headline,
          (.branch // "(detached)"),
          (.ahead // "?"),
          (if .dirty == null then "-" else .dirty end),
          .upstream,
          (if .prNumber == null then .prState else "\(.prState) #\(.prNumber)" end),
          (.mergeProof // "-"),
          (.path // "(no worktree)")] | @tsv' "$STATUS_ROWS" |
    while IFS=$'\t' read -r c1 c2 c3 c4 c5 c6 c7 c8; do
      printf '%-9s %-40s %5s %5s %-9s %-13s %-16s %s\n' "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" "$c7" "$c8"
    done
  printf 'measured against: %s' "$STATUS_PROTECTED"
  if [[ "$STATUS_PR_SOURCE" == "gh" ]]; then
    printf '; pr source: gh\n'
  elif [[ -n "$STATUS_PR_ERROR" ]]; then
    printf '; pr source: %s (%s) -- PR column is unknown, not none\n' "$STATUS_PR_SOURCE" "$STATUS_PR_ERROR"
  else
    printf '; pr source: %s -- PR column is unknown, not none\n' "$STATUS_PR_SOURCE"
  fi
}

case "$cmd" in
  new)
    branch="${2:?usage: worktree.sh new <branch> [start-point]}"
    slug="${branch//\//-}"
    path="$wt_root/$slug"
    mkdir -p "$wt_root"
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      git worktree add "$path" "$branch"
    else
      git worktree add -b "$branch" "$path" "${3:-HEAD}"
    fi
    echo
    echo "worktree ready: $path"
    echo "next: cd \"$path\" and start the agent session there."
    ;;
  ls)
    git worktree list
    ;;
  path)
    branch="${2:?usage: worktree.sh path <branch>}"
    slug="${branch//\//-}"
    wt_resolve "$slug"
    ;;
  rm)
    branch="${2:?usage: worktree.sh rm <branch>}"
    slug="${branch//\//-}"
    path="$(wt_resolve "$slug")"
    git worktree remove "$path"
    echo "removed $path (branch \"$branch\" kept — git branch -d when merged)"
    ;;
  status)
    case "${2:-}" in
      "") status_report 0 ;;
      --json) status_report 1 ;;
      *) usage ;;
    esac
    ;;
  *)
    usage
    ;;
esac
