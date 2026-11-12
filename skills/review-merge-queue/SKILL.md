---
name: review-merge-queue
description: Take the open pull requests, triage them into what can be reviewed and what is waiting on something else, dispatch one fresh adversarial reviewer per reviewable PR briefed to falsify that PR's own claims, and post a verdict on each. User-invoked as /review-merge-queue [number|limit].
argument-hint: "[PR number, or a limit like 3]"
disable-model-invocation: true
---

# Review the merge queue

A pull request is not reviewed because somebody wandered past it. This takes
the queue, decides which PRs are actually reviewable, and dispatches one fresh
reviewer per PR with that PR's own claims as the thing to falsify.

Why it exists: on 2026-11-10 three open PRs each held a defect that an
adversarial reviewer found and the author had not — including a branch whose
first three fixes were each correct for the location they were written against
and wrong one door over. In every case the review that mattered was an
independent agent briefed to attack a specific claim. In no case was that
review a standing step.

**It reports. Merging is decided by `mergePolicy`, not by this skill** — see
step 4.

## Procedure

### 1. Survey, and triage before spending anything

```sh
gh pr list --state open --limit 100 \
  --json number,title,headRefOid,baseRefName,mergeStateStatus,reviewDecision,isDraft,author
```

Sort each PR into one bucket. Only the last is reviewable, and saying why the
others are not is most of this skill's value:

| bucket | signal | what it needs instead of a review |
|---|---|---|
| draft | `isDraft` | nothing; the author is still working |
| conflicted | `mergeStateStatus` is `CONFLICTING`/`DIRTY` | a merge-forward or rebase first; a review of a diff that cannot land is wasted |
| stacked child | its base branch is merged or gone | retarget with `gh pr edit <n> --base <trunk>` — nothing does this automatically, and the child's diff shows only its own commits, so nothing in it signals the dependency |
| behind | `BEHIND` | `gh pr update-branch <n>`; branch protection requires it before merge anyway |
| held | the newest review comment states a blocking finding and no commit has landed since | the fix, by its author; re-reviewing an unaddressed finding says nothing new |
| already judged | a verdict comment on this PR names the current `headRefOid` | nothing; the verdict stands until the head moves |
| **reviewable** | green, unblocked, head not yet judged | one fresh reviewer, step 2 |

`already judged` is what makes this safe to re-run: the pass is keyed on the
head SHA, so running it twice in a row costs nothing and a new commit is what
earns a new review.

### 2. Cap it, and say what you capped

A reviewer run per PR is real time and real tokens. Default to **three**
reviewable PRs, ordered by closeness to mergeable (green and unblocked first,
then `BEHIND`), and name the ones you did not take. `/review-merge-queue 6`
raises the cap; `/review-merge-queue 113` reviews exactly that PR.

### 3. One fresh reviewer per PR

The brief is the PR's own claims, not its diff summary. Write it per
[BRIEF](BRIEF.md), which is the part that decides whether a verdict is worth
anything, and size it per [the agents README](../../agents/README.md): about
25 tool calls, verdict-bearing steps first, and "mark anything unreached
*insufficient coverage*".

Never the authoring session's own context. If this session wrote the PR, that
is exactly why the reviewer is a subagent: the author's verification is a claim
to falsify, not evidence.

### 4. Post the verdict, then let the policy decide the ending

One comment per PR: the verdict, each finding with its evidence, and what the
reviewer did not reach. Then resolve `mergePolicy` once
(`bin/llmctx explain mergePolicy`, or the key in `.llmctx.json`, default
`hold`) and act on it, exactly as [grab](../grab/) does:

- **`hold`** — stop. Say which PRs are ready and which have findings.
- **`review-and-merge`** — for a `CLEAN` verdict: update the branch, wait for
  CI on the merge result, merge, then clean up by the global guidelines' §5
  rules. A finding goes back to its author through fix → re-review, never a
  quiet patch. If `gh pr merge` is refused by a permission rule, say so and
  fall back to `hold` out loud; a refusal is not a verdict on the work.
- **`queue`** — say which are ready, with verdicts, and stop.

A `DO-NOT-MERGE` verdict is never merged under any policy.

## Rules

- Triage before reviewing. A review of a conflicted or held PR is waste.
- One PR, one brief, one reviewer. Never one brief covering two PRs.
- Keyed on the head SHA: an unchanged head is not re-reviewed.
- The reviewer reports; it never edits, pushes, merges or comments itself.
- Never merge a `DO-NOT-MERGE`, and never merge on your own verification.

## Related

- [start-a-session](../start-a-session/) names the merge queue as a seam and
  dispatches here.
- [grab](../grab/) owns the same `mergePolicy` ending for a single branch.
- [triage](../triage/) is the issue-side equivalent; its "argue the other side"
  step is where the case-against discipline comes from.
