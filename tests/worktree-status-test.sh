#!/usr/bin/env bash
set -euo pipefail

# Cover for `bin/worktree.sh status`.
#
# Why it exists: three worktrees held finished, tested, unpushed work with no
# PR and no ticket, a fourth held a whole skill staged and never committed,
# and nothing in the tooling could say so. The one proof that matters is the
# squash-merge one -- `git merge-base --is-ancestor <branch> main` reports
# "not merged" about every correctly squash-merged branch, so `status` must
# prove a merge against the merged PR's headRefOid instead, and must say
# `unknown` rather than `none` whenever it could not ask GitHub.
#
# `gh` is faked: a shim on PATH that answers `pr list` from a fixture and
# refuses anything else. This is the first fake executable in the suite; the
# symlink allowlist from env-check-test.sh is reused for the gh-missing case.
#
# Isolation: every repository here is created under $tmp, so the real
# repository's worktree list is never touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
WT="$SRC/bin/worktree.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/llmctx-worktree-status-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

export GIT_CONFIG_GLOBAL="$tmp/global.gitconfig"
: >"$GIT_CONFIG_GLOBAL"
export HOME="$tmp/home"
mkdir -p "$HOME"

fail() {
  echo "worktree-status test failed: $*" >&2
  exit 1
}

gitc() { # gitc <dir> <args...>: git with a committer identity
  local dir="$1"
  shift
  git -C "$dir" -c user.email=t@example.com -c user.name=t "$@"
}

# A commit on a branch that has no checkout anywhere: commit-tree + update-ref.
branch_with_commit() { # branch_with_commit <branch> <parent-ref> <msg>
  local tree sha
  tree="$(git -C "$repo" rev-parse "$2^{tree}")"
  sha="$(gitc "$repo" commit-tree -p "$2" -m "$3" "$tree")"
  git -C "$repo" update-ref "refs/heads/$1" "$sha"
}

# --- fixtures -------------------------------------------------------------------

origin="$tmp/origin.git"
git init -q --bare -b main "$origin"

repo="$tmp/org/demo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
gitc "$repo" commit -q --allow-empty -m "root"
root_sha="$(git -C "$repo" rev-parse HEAD)"
printf '%s\n' '{"schemaVersion":1,"protectedBranches":["main"],"strandedExempt":["backup/"]}' >"$repo/.llmctx.json"
git -C "$repo" add .llmctx.json
gitc "$repo" commit -q -m "policy"
git -C "$repo" remote add origin "$origin"
git -C "$repo" push -q -u origin main

new_wt() { # new_wt <branch> -> path
  (cd "$repo" && "$WT" new "$1" >/dev/null 2>&1)
  (cd "$repo" && "$WT" path "$1")
}

# 1. commits, no PR -> STRANDED
wt_stranded="$(new_wt feature/stranded)"
gitc "$wt_stranded" commit -q --allow-empty -m "stranded work"

# 2. merged PR whose head IS this tip -> merged-exact
wt_exact="$(new_wt feature/merged-exact)"
gitc "$wt_exact" commit -q --allow-empty -m "exact"
sha_exact="$(git -C "$wt_exact" rev-parse HEAD)"

# 3. merged PR whose head is one commit PAST this tip -> merged-ancestor
wt_anc="$(new_wt feature/merged-ancestor)"
gitc "$wt_anc" commit -q --allow-empty -m "anc 1"
sha_anc1="$(git -C "$wt_anc" rev-parse HEAD)"
gitc "$wt_anc" commit -q --allow-empty -m "anc 2"
sha_anc2="$(git -C "$wt_anc" rev-parse HEAD)"
git -C "$wt_anc" reset -q --hard "$sha_anc1"

# 4. merged PR whose head is unrelated to this tip -> diverged
wt_div="$(new_wt feature/diverged)"
gitc "$wt_div" commit -q --allow-empty -m "diverged work"

# 5. merged PR whose head was never fetched -> unverifiable, not diverged
wt_unv="$(new_wt feature/unverifiable)"
gitc "$wt_unv" commit -q --allow-empty -m "unverifiable"
sha_missing="0123456789abcdef0123456789abcdef01234567"

# 6. open PR, pushed -> OPEN, upstream present
wt_open="$(new_wt feature/open)"
gitc "$wt_open" commit -q --allow-empty -m "open work"
git -C "$wt_open" push -q -u origin feature/open

# 7. zero commits, staged + untracked -> DIRTY
wt_dirty="$(new_wt feature/dirty)"
echo staged >"$wt_dirty/staged.txt"
git -C "$wt_dirty" add staged.txt
echo untracked >"$wt_dirty/untracked.txt"

# 8. exempt prefix, no worktree -> reported, not STRANDED
branch_with_commit backup/old main "backup"

# 9. commits, no worktree, no PR -> STRANDED in branches
branch_with_commit feature/no-worktree main "no worktree"

# 10. zero commits, no worktree -> not listed at all
git -C "$repo" branch feature/empty main

# 11. detached worktree with a commit -> UNKNOWN (nothing to look up)
git -C "$repo" worktree add -q --detach "$tmp/detached" main
gitc "$tmp/detached" commit -q --allow-empty -m "detached work"

# 12. upstream states: gone, and behind
wt_gone="$(new_wt feature/gone)"
gitc "$wt_gone" commit -q --allow-empty -m "gone work"
git -C "$wt_gone" push -q -u origin feature/gone
git -C "$repo" update-ref -d refs/remotes/origin/feature/gone
git -C "$repo" branch -q feature/behind "$root_sha"
git -C "$repo" branch -q -u origin/main feature/behind
git -C "$repo" worktree add -q "$tmp/behind" feature/behind

# 18. Work that landed on origin/main with no PR, while LOCAL main is still
# behind. Measured against local main alone this branch has one unlanded
# commit and would read STRANDED; measured against origin/main too it has
# nothing unlanded and must produce no row at all. This is why protected refs
# include the origin/ copy, and the case that pins it.
clone="$tmp/clone"
git clone -q "$origin" "$clone"
git -C "$clone" checkout -q -b feature/landed-upstream
gitc "$clone" commit -q --allow-empty -m "landed upstream, no PR"
git -C "$clone" checkout -q main
git -C "$clone" merge -q --ff-only feature/landed-upstream
git -C "$clone" push -q origin main
git -C "$repo" fetch -q origin main # origin/main moves; local main does not
git -C "$repo" branch -q feature/landed-upstream origin/main

# The fake gh. It answers `pr list` from the fixture and refuses anything else.
mkdir -p "$tmp/fakebin"
prs="$tmp/prs.json"
# `pr list` answers from the first-page fixture; `pr list --head <branch>` from
# the full fixture, filtered -- which is how the real gh behaves when a page
# is full and status looks a branch up by name.
prs_all="$tmp/prs-all.json"
cat >"$tmp/fakebin/gh" <<SHIM
#!/bin/sh
case "\$1 \$2 \$3" in
  "pr list --head") jq -c --arg b "\$4" '[.[] | select(.headRefName == \$b)]' "$prs_all" ;;
  "pr list "*) cat "$prs" ;;
  *) echo "fake gh: unexpected args: \$*" >&2; exit 99 ;;
esac
SHIM
chmod +x "$tmp/fakebin/gh"

jq -n --arg exact "$sha_exact" --arg anc "$sha_anc2" --arg root "$root_sha" --arg missing "$sha_missing" '[
  {headRefName: "feature/merged-exact",    number: 1, state: "MERGED", headRefOid: $exact},
  {headRefName: "feature/merged-ancestor", number: 2, state: "MERGED", headRefOid: $anc},
  {headRefName: "feature/diverged",        number: 3, state: "MERGED", headRefOid: $root},
  {headRefName: "feature/unverifiable",    number: 4, state: "MERGED", headRefOid: $missing},
  {headRefName: "feature/open",            number: 5, state: "OPEN",   headRefOid: "ffffffffffffffffffffffffffffffffffffffff"}
]' >"$prs"
cp "$prs" "$prs_all"

run_status() { # run_status <cwd> [args...]
  local dir="$1"
  shift
  (cd "$dir" && PATH="$tmp/fakebin:$PATH" "$WT" status "$@")
}

# --- the report -----------------------------------------------------------------

out="$(run_status "$repo" --json)"
printf '%s\n' "$out" >"$tmp/report.json"

wt_row() { # wt_row <branch>
  jq -c --arg b "$1" '.worktrees[] | select(.branch == $b)' "$tmp/report.json"
}
br_row() { # br_row <branch>
  jq -c --arg b "$1" '.branches[] | select(.branch == $b)' "$tmp/report.json"
}
field() { # field <row-json> <jq-expr>
  jq -r "$2" <<<"$1"
}

jq -e '.prSource == "gh" and .prError == null and .protectedBranches == ["main"]' "$tmp/report.json" >/dev/null ||
  fail "report header: $(jq -c '{prSource,prError,protectedBranches}' "$tmp/report.json")"
[[ "$(jq -r .repository "$tmp/report.json")" = "$repo" ]] ||
  fail "repository was not the main checkout: $(jq -r .repository "$tmp/report.json")"

# 1
r="$(wt_row feature/stranded)"
[[ "$(field "$r" .headline)" = STRANDED && "$(field "$r" .ahead)" = 1 && "$(field "$r" .prState)" = none ]] ||
  fail "stranded: $r"
# 2
r="$(wt_row feature/merged-exact)"
[[ "$(field "$r" .headline)" = MERGED && "$(field "$r" .mergeProof)" = merged-exact && "$(field "$r" .prNumber)" = 1 ]] ||
  fail "merged-exact: $r"
# 3 -- the squash-merge proof. `merge-base --is-ancestor <tip> main` is false
# here; the tip is an ancestor of the merged PR's head, and that is the proof.
r="$(wt_row feature/merged-ancestor)"
[[ "$(field "$r" .headline)" = MERGED && "$(field "$r" .mergeProof)" = merged-ancestor ]] ||
  fail "merged-ancestor: $r"
# 4
r="$(wt_row feature/diverged)"
[[ "$(field "$r" .headline)" = DIVERGED && "$(field "$r" .mergeProof)" = diverged ]] ||
  fail "diverged: $r"
# 5
r="$(wt_row feature/unverifiable)"
[[ "$(field "$r" .headline)" = MERGED && "$(field "$r" .mergeProof)" = unverifiable ]] ||
  fail "unverifiable: $r"
# 6
r="$(wt_row feature/open)"
[[ "$(field "$r" .headline)" = OPEN && "$(field "$r" .upstream)" = present && "$(field "$r" .prNumber)" = 5 ]] ||
  fail "open: $r"
# 7
r="$(wt_row feature/dirty)"
[[ "$(field "$r" .headline)" = DIRTY && "$(field "$r" .ahead)" = 0 && "$(field "$r" .dirty)" = 2 &&
"$(field "$r" .staged)" = 1 && "$(field "$r" .unstaged)" = 0 && "$(field "$r" .untracked)" = 1 ]] ||
  fail "dirty: $r"
# 8
r="$(br_row backup/old)"
[[ -n "$r" && "$(field "$r" .exempt)" = true && "$(field "$r" .headline)" != STRANDED && "$(field "$r" .ahead)" = 1 ]] ||
  fail "exempt: $r"
# 9
r="$(br_row feature/no-worktree)"
[[ -n "$r" && "$(field "$r" .headline)" = STRANDED && "$(field "$r" .path)" = null ]] ||
  fail "no-worktree: $r"
# 10
r="$(wt_row main)"
[[ "$(field "$r" .headline)" = - && "$(field "$r" .ahead)" = 0 ]] ||
  fail "main row: $r"
[[ -z "$(br_row feature/empty)" && -z "$(wt_row feature/empty)" ]] ||
  fail "a branch with no commits and no worktree was listed"
# Branches that have a worktree appear once, under worktrees, never again
# under branches.
for b in feature/stranded feature/open feature/dirty main; do
  [[ -z "$(br_row "$b")" ]] || fail "$b has a worktree but was also listed under branches"
done
# 11
r="$(jq -c '.worktrees[] | select(.branch == null)' "$tmp/report.json")"
[[ -n "$r" && "$(field "$r" .headline)" = UNKNOWN && "$(field "$r" .prState)" = unknown && "$(field "$r" .ahead)" = 1 ]] ||
  fail "detached: $r"
# 12
r="$(wt_row feature/gone)"
[[ "$(field "$r" .upstream)" = gone && "$(field "$r" .headline)" = STRANDED ]] ||
  fail "gone: $r"
r="$(wt_row feature/behind)"
# Behind by two: the policy commit, and the commit case 18 landed on origin/main.
[[ "$(field "$r" .upstream)" = behind && "$(field "$r" .upstreamBehind)" = 2 && "$(field "$r" .ahead)" = 0 ]] ||
  fail "behind: $r"
# 18
[[ -z "$(br_row feature/landed-upstream)" && -z "$(wt_row feature/landed-upstream)" ]] ||
  fail "a branch already on origin/main (local main behind) was listed: $(br_row feature/landed-upstream)"
[[ "$(wt_row main | jq -r .ahead)" = 0 ]] || fail "local main behind origin/main was counted as ahead"

# 16. From inside a linked worktree the report is the same report.
out2="$(run_status "$wt_stranded" --json)"
[[ "$out2" = "$out" ]] || fail "report from inside a worktree differed from the primary's"

# 17. The human table says the same thing, and exits 0.
table="$(run_status "$repo")"
grep -q '^STRANDED  *feature/stranded ' <<<"$table" || fail "table has no STRANDED line for feature/stranded"
grep -q '^MERGED  *feature/merged-ancestor .*merged-ancestor' <<<"$table" || fail "table has no merged-ancestor proof"
grep -q 'pr source: gh$' <<<"$table" || fail "table footer did not name the pr source"
status=0
run_status "$repo" --bogus >/dev/null 2>&1 || status=$?
[[ "$status" -ne 0 ]] || fail "status --bogus exited 0"

# 13. gh present but failing: every unlanded row is UNKNOWN, none STRANDED.
cat >"$tmp/fakebin/gh" <<'SHIM'
#!/bin/sh
echo "error connecting to api.github.com" >&2
exit 1
SHIM
out="$(run_status "$repo" --json)"
jq -e '.prSource == "gh-failed" and (.prError | test("api.github.com"))' <<<"$out" >/dev/null ||
  fail "gh-failed header: $(jq -c '{prSource,prError}' <<<"$out")"
jq -e '[(.worktrees[], .branches[]) | select(.ahead > 0) | .headline] | all(. == "UNKNOWN")' <<<"$out" >/dev/null ||
  fail "gh-failed: $(jq -c '[(.worktrees[], .branches[]) | select(.ahead > 0) | {branch,headline}]' <<<"$out")"
jq -e '[(.worktrees[], .branches[]) | .headline] | any(. == "STRANDED") | not' <<<"$out" >/dev/null ||
  fail "gh-failed still produced STRANDED"
grep -q 'pr source: gh-failed (error connecting' <<<"$(run_status "$repo")" ||
  fail "table footer did not carry the gh error"

# 15. gh present but the first page is as long as the limit: a missing row
# proves nothing, so the branch is looked up by name. The full fixture holds
# the merged PR the first page cut off; a branch with no PR anywhere is then
# confidently `none`, and STRANDED. Only when the lookup itself fails is it
# `unknown`.
jq -n '[range(0; 200) | {headRefName: "x\(.)", number: ., state: "CLOSED", headRefOid: "0000000000000000000000000000000000000000"}]' >"$prs"
jq -n --arg exact "$sha_exact" '[{headRefName: "feature/merged-exact", number: 1, state: "MERGED", headRefOid: $exact}]' >"$prs_all"
cat >"$tmp/fakebin/gh" <<SHIM
#!/bin/sh
case "\$1 \$2 \$3" in
  "pr list --head") jq -c --arg b "\$4" '[.[] | select(.headRefName == \$b)]' "$prs_all" ;;
  *) cat "$prs" ;;
esac
SHIM
out="$(run_status "$repo" --json)"
jq -e '.prSource == "gh-truncated"' <<<"$out" >/dev/null || fail "gh-truncated was not detected"
r="$(jq -c '.worktrees[] | select(.branch == "feature/merged-exact")' <<<"$out")"
[[ "$(field "$r" .mergeProof)" = merged-exact && "$(field "$r" .headline)" = MERGED ]] ||
  fail "a branch cut off the first page was not looked up by name: $r"
r="$(jq -c '.worktrees[] | select(.branch == "feature/stranded")' <<<"$out")"
[[ "$(field "$r" .prState)" = none && "$(field "$r" .headline)" = STRANDED ]] ||
  fail "a branch with no PR anywhere was not confidently none after lookup: $r"
cat >"$tmp/fakebin/gh" <<SHIM
#!/bin/sh
case "\$1 \$2 \$3" in
  "pr list --head") echo "error connecting" >&2; exit 1 ;;
  *) cat "$prs" ;;
esac
SHIM
out="$(run_status "$repo" --json)"
[[ "$(jq -r '.worktrees[] | select(.branch == "feature/stranded") | .prState' <<<"$out")" = unknown ]] ||
  fail "a branch whose lookup failed on a truncated page was not unknown"

# 14. gh absent: the allowlist idiom from env-check-test.sh, with gh left out.
mkdir -p "$tmp/minbin"
for tool in bash git jq awk sed grep dirname basename cat head mktemp rm sort tr cut env; do
  real="$(command -v "$tool" 2>/dev/null)" || continue
  ln -sf "$real" "$tmp/minbin/$tool"
done
out="$(cd "$repo" && PATH="$tmp/minbin" "$WT" status --json)"
jq -e '.prSource == "gh-missing" and .prError == null' <<<"$out" >/dev/null ||
  fail "gh-missing header: $(jq -c '{prSource,prError}' <<<"$out")"
[[ "$(jq -r '.worktrees[] | select(.branch == "feature/stranded") | .headline' <<<"$out")" = UNKNOWN ]] ||
  fail "gh-missing did not make the stranded row UNKNOWN"

echo "worktree-status tests: passed"
