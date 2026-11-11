---
name: grab
description: Grab a unit of work — take a ticket, create the branch and worktree, record the working brief where the repo keeps them, and start implementing. User-invoked as /grab <issue-or-brief>.
disable-model-invocation: true
---

# Grab

Connects the pipeline's pieces into one motion: issue → worktree → brief →
implementation. Designed so several grabs can run in parallel, one agent
session per worktree.

## Procedure

1. **Resolve the work item.** `/grab <issue-id>` fetches the issue from the
   repo's tracker (which tracker: see the repo's CLAUDE.md/AGENTS.md and
   [setup-skills](../setup-skills/)). `/grab` with no argument: list open,
   unassigned, ready-labeled issues and ask which one. If pointed at an
   existing brief file, use it directly.

2. **Qualify before building.** Read the issue. If it lacks what
   [AGENT-BRIEF](../triage/AGENT-BRIEF.md) requires — context, constraints,
   verification criteria — apply [interview-me](../interview-me/) to close the gaps
   (asking the user or the issue thread) rather than guessing. A brief
   without "done means…" is not grabbable yet.

3. **Create the workspace.** Branch name `feature/<issue-id>-<slug>` (or
   `fix/…`), then create the worktree **with the repo's own helper**, which
   `docs/agents/workflow.md` names where `setup-skills` has been run here (the
   repo's CLAUDE.md/AGENTS.md otherwise). `scripts/new-worktree.sh <branch>` and
   its equivalents encode that repo's base branch, location convention and
   pre-flight — a helper that fetches `origin/main` first, because a stale base is
   how you author a migration chaining off a superseded head. Fall back to
   `agent-harness/bin/worktree.sh new <branch>` only where the repo ships nothing.
   All subsequent work happens inside that worktree, leaving the main checkout
   free for parallel grabs.

4. **Record the working brief where THIS repo keeps briefs**, per the
   AGENT-BRIEF format, and note on the tracker issue that it's been grabbed
   (assignee/label per repo convention). **Find out where briefs go before
   creating a file for one** — `docs/agents/workflow.md` where `setup-skills` has
   been run, the repo's CLAUDE.md/AGENTS.md otherwise. Some repos commit briefs under
   `docs/briefs/`; others have retired that path deliberately and gitignore it,
   because a brief that restates its ticket is a second copy free to drift — in
   those, the brief IS the ticket, working notes stay local and uncommitted, and
   there is nothing to write. Never create a briefs directory a repo does not
   already use.

5. **Implement**, honoring the brief's verification criteria as the
   definition of done. Use [tdd](../tdd/) where possible, at pre-agreed seams.
   Run typechecking regularly, single test files regularly, and the full test
   suite once at the end. Before review, check the work against the
   verification criteria the brief gave you: state each criterion and the
   evidence that it is met — a test name, a command's output, a file path —
   not a claim that it is met. Where a criterion cannot be verified as stated,
   say so rather than reinterpreting it into something that passes. Unmet or
   unverifiable criteria go on the ticket, not into the commit message. Then
   use `/code-review` to review the work, and commit to the branch. On
   completion or when stopping mid-flight, write a handoff per
   [handoff](../handoff/) so any agent — or a human — can resume.

6. **When you are asked to publish the work** — and not before, because
   nothing pushes or opens a pull request without being asked — what happens
   next is the repository's call, not yours. Resolve it:
   `bin/llmctx explain mergePolicy` (agent-harness; elsewhere read
   `mergePolicy` in `.llmctx.json`, defaulting to `hold`).

   - **`hold`** — push, open the pull request, record the review on it, say it
     is ready, and stop. The merge is a person's.
   - **`review-and-merge`** — dispatch a **fresh** reviewer, never this
     session's own context, briefed to falsify the claims the PR body makes
     (see [the agents README](../../agents/README.md) on sizing that brief).
     Merge only on a clean verdict, and only after CI is green on the merge
     result: branch protection usually requires the branch to be up to date,
     so update it first. A finding goes back through fix and re-review, never
     a quiet patch. Then clean up the worktree and branch by the global
     guidelines' §5 rules. If `gh pr merge` is refused by a permission rule,
     say so and fall back to `hold` out loud — do not treat the refusal as a
     verdict on the work.
   - **`queue`** — say it is ready, with the review verdict, and move on. The
     merge belongs to whoever owns the queue.

## Rules
- One grab = one branch = one worktree = one brief. No batching.
- Never grab onto main/master; the worktree step makes this structural.
- If the tracker and the brief file disagree, the tracker wins (see the
  global handoff-and-briefs conventions).

## Related
- [triage](../triage/) · [to-issues](../to-issues/) · [tdd](../tdd/) · [handoff](../handoff/) · [start-a-session](../start-a-session/)
