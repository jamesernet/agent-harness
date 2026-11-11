# Global Behavioral Guidelines

Applies to all projects. When these conflict with a project's own instructions or existing conventions, the project wins.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

For non-trivial decisions, work as a thoughtful collaborator: present the options, explain the tradeoffs, recommend a path, and state your assumptions. Prefer practical, simple, portable solutions.

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.
- Proceed when the remaining open questions wouldn't change the approach; otherwise ask — focused questions, only where the answer materially changes the outcome.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Break implementation into the smallest logical, independently verifiable steps
that still produce meaningful progress. Complete and verify one step before
starting the next. When committing is part of the task, keep the same boundaries:
one logical theme per commit rather than one large catch-all commit.

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

## 5. Branch Before You Build

**Never work directly on `main`/`master`.** Before starting changes in a repo, create a working branch from the current branch:

```
git checkout -b feature/<short-description>
```

A long-lived integration branch (e.g. `stage`) is fine too — the rule is simply that `main`/`master` stay clean until a change is ready to merge. Branch names should describe the work, not the date.

A backstop (remote branch protection, a pre-commit hook, or a tool-level guard) should enforce this; this rule is the intent. If a guard blocks you, branch first, then retry.

How hard the tool-level guard pushes is a per-repo decision: `off`, `remind` (once per session), `ask`, or `deny`. A committed `client` profile defaults to `deny`; the built-in and `personal` defaults are `remind`. A personal repo that legitimately lives on one branch can override the policy locally with `off`. **The rule above holds regardless of the setting** — the policy tunes the interruption, not the convention. A guard that is wrong half the time gets disabled entirely, and then it protects nothing.

**When parallel sessions may run against the same repo, worktree before you build.** git has one `HEAD` per working directory, so two sessions (agents or humans) sharing one checkout will land commits on whatever branch is checked out at that instant and tangle histories. Give each feature branch its own git worktree instead of switching branches in a shared checkout:

```
git worktree add -b feature/<short-description> ../<repo>-worktrees/<slug> <base>
```

Run one session per worktree; remove it (`git worktree remove`) once merged. Solo, single-session work may branch in the main checkout **unless the repo's own hooks refuse it** — check `.git/hooks/pre-commit`, `.githooks/pre-commit` and `core.hooksPath` before assuming, because a repo that enforces worktree-per-branch unconditionally will refuse the commit after you have done the work, not before. A repo may carry either location, both, or neither: the branch backstop installs into `.git/hooks/`, which is never cloned, while a scaffolded repo commits its own hook to `.githooks/`. **A missing `.githooks/` is not evidence that nothing will refuse the commit.** `llmctx repo diff .` answers the question directly. A repo may ship a helper (e.g. `scripts/new-worktree.sh`) that encodes its base branch and location convention; prefer it over the raw command above.

**Clean up completed work.** When you know a feature branch has been merged into
`main`, `master`, or the repo's integration branch (for example `stage`):

1. Verify the worktree is clean.
2. Prove the merge **in the way the repo's history allows**, then remove the linked
   worktree and delete the branch with `git branch -d`.

`git merge-base --is-ancestor <branch> <target>` is the proof only where merges preserve
commits. **Under squash merges it reports "not merged" for every correctly-merged
branch**, because what landed is a new commit with a different SHA. Where a repo ships a
pruning helper (e.g. `scripts/prune-worktrees.sh`), use it: the workable proof there is
matching the branch tip against the merged PR's `headRefOid`, which also catches commits
pushed after the merge.

**That does not mean you are left with `git branch -D`.** `-d` checks *merged to its
upstream*, not only *merged to HEAD*, so a branch you **pushed** — whose remote-tracking
ref still points at the same commit — deletes cleanly with no force, warning that it was
merged to its upstream rather than to HEAD.

**That ref has to still exist, and the usual cleanup destroys it.**
`gh pr merge --delete-branch` removes the *remote* branch, so after the next
`fetch --prune` there is no upstream left to compare against and `-d` refuses again.
Measured against a scratch repo with a real remote and a real squash merge: pushed with
the ref intact **deletes**, never pushed **refuses**, pushed-then-remote-deleted
**refuses**. So `-d` is the case *before* cleanup rather than the usual case, and the
ORDER decides which one you are in — delete the local branch while its remote-tracking
ref is still there, or fall back to the helper's `headRefOid` proof, which does not care
either way.

`-D` is only reached for a branch that never left the machine, and there "merged" is not
a question git can answer at all — so it is still not the answer.

**A stack merges parent-first, and the child does not follow on its own.** Where one
branch is based on another and both have PRs, merging the parent leaves the child still
based on a branch that is now in the trunk. Retarget it explicitly, between the two
merges:

```
gh pr merge <parent> --merge
gh pr edit  <child> --base <trunk>     # nothing does this for you
gh pr merge <child> --merge
```

Measured on 2026-09-24 against a real two-PR stack: the parent merged **without**
`--delete-branch`, per the rule above, and the child's base was unchanged afterwards;
`gh pr edit` moved it. Deleting the parent branch is said to retarget the child for you,
but that is the thing the rule above forbids, so it is not the route.

Say in the child's body that it is stacked, on what, and that its base retargets once the
parent lands. **The child's diff shows only its own commits**, so nothing in it signals
that it depends on unmerged work — which is the trap: it reads as self-contained, and can
be approved and merged out of order by a reviewer who never sees the dependency.

If the target branch is ambiguous, the worktree is dirty, or the merge cannot be proven
by a method that fits the repo's merge strategy, stop and ask. Never force-delete a
branch or delete a remote branch without an explicit request.

## 6. Operating Safety

**Secrets:** Never commit secrets or print credential/env values. If you spot a hardcoded secret or key, stop and flag it — don't "fix" it silently.

**Irreversible actions:** Before `rm -rf`, dropping DBs/tables, running migrations against non-local environments, force-push, history rewrite, or deleting branches — stop and confirm. The only standing exception is deleting a clean local worktree and local branch after the merged-work cleanup checks above prove the branch is fully merged.

**Commits & PRs:** Small, logically-scoped commits, with a subject that describes the commit's overall theme. Keep the subject to a single line that reads comfortably in a terminal; **where a repo has an observed convention, follow that instead** — some write the subject as a claim and legitimately run past 72 characters, and some have their tooling append a PR number you must therefore not type yourself. Add a body only when additional context materially helps the reviewer. Do not add `Co-authored-by:` trailers or other co-author attribution. Never push or open a PR without an explicit ask.
