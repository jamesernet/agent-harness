# Work artifacts and worktrees

Seed template. `setup-skills` writes this to `docs/agents/workflow.md`; `grab`, `handoff`
and `triage` read it. Replace the bracketed parts and delete the options that do not apply.

## Where a brief lives

**[Choose one and delete the other.]**

**On the tracker only.** The ticket *is* the brief. Nothing is committed. A brief that
restates its ticket is a second copy free to drift, so there is no file to write and no
directory to create. Working notes stay wherever the agent tool puts temporary files, and are
never committed. Where `.llmctx.json` declares `"briefs": "tracker"`, that file is the
record of the decision — state the consequence here and point at it, rather than restating
the choice and creating the second copy this section exists to prevent.

**Committed under `docs/briefs/`.** One file per brief, `docs/briefs/<issue-id>-<slug>.md`,
written in the worktree. The tracker is still the source of truth: if the file and the
tracker disagree, the tracker wins and the file gets updated.

## Where a mid-flight handoff goes

**[Choose one and delete the other.]**

**A comment on the ticket.** Say what you did, what you were about to do, and what you
learned that the ticket does not already say. Then stop. The next session resumes from the
ticket, not from memory and not from a file.

**A file under `docs/briefs/handoffs/`.** Named `<yyyy-mm-dd>-<slug>.md`. Delete it once the
next session has absorbed it.

## Creating a worktree

**[Name the repo's own helper if it ships one, else say so.]**

- Helper: `[scripts/new-worktree.sh <branch>]` — use this rather than a raw
  `git worktree add`. A repo helper encodes the base branch, the worktree location, and any
  pre-flight the repo needs. **Say what the pre-flight is for**, so nobody skips it:
  `[e.g. it fetches origin/main first, because a stale base is how you author a migration
  chaining off a superseded head]`.
- Pruning: `[scripts/prune-worktrees.sh]` — `[dry run unless --apply; --apply needs a named
  target or --all]`.
- **No helper.** Use `git worktree add -b <branch> ../<repo>-worktrees/<slug> <base>` and
  branch from `[origin/main]`.

## Proving a branch merged, before deleting it

**[Choose the one that matches this repo's merge strategy.]**

**Squash merges.** `git merge-base --is-ancestor` can never pass — what landed is a new
commit with a different SHA, so it reports "not merged" for every correctly-merged branch.
`git cherry` only helps for a single-commit branch, because squashing N commits produces a
patch-id matching none of them. Prove it by state plus content: the PR is `MERGED` **and**
the branch tip matches its `headRefOid` (the tip check is what catches commits pushed after
the merge), or every file the PR touched is byte-identical on the trunk. Where the repo
ships a pruning helper, it already does this — use it.

**Merge commits preserved.** `git merge-base --is-ancestor <branch> <target>` is the proof,
and `git branch -d` enforces it for you.

Either way: never `git branch -D` to work around a proof that will not pass.

## Commit subjects

**[Record the repo's observed convention, measured rather than assumed. Delete if there is
nothing beyond the global rule.]**

- Prefix style: `[none — conventional-commit prefixes are not used here]`
- Issue/PR reference: `[appended automatically by the forge on squash merge — do NOT type
  one, or the subject ends up doubled]`
- Length: `[measured median and spread, so it reads as an observation and not a target]`
