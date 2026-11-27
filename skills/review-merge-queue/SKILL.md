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
| **reviewable** | green, unblocked, head not yet judged | one fresh reviewer, step 2; a head that moved only by a fix or a tests-only commit after a verdict is judged by step 5 instead |

`already judged` is what makes this safe to re-run: the pass is keyed on the
head SHA, so running it twice in a row costs nothing and a new commit is what
earns a new review.

### 2. Cap it, and say what you capped

A reviewer run per PR is real time and real tokens. Default to **three**
reviewable PRs, ordered by closeness to mergeable (green and unblocked first,
then `BEHIND`), and name the ones you did not take. `/review-merge-queue 6`
raises the cap; `/review-merge-queue 113` reviews exactly that PR.

### 3. One fresh reviewer per PR

The reviewer is the managed `reviewer` agent where it is installed, or the
nearest independent equivalent. `/code-review` in the authoring session is the
author's own pre-publication pass ([grab](../grab/) step 5); it comes before
this verdict and does not replace it.

Resolve branch updates before dispatching the reviewer, then record the exact
head being reviewed. If that head changes at any later step, including during a
merge-forward, invalidate the old verdict and obtain a fresh independent review
and required CI for the new head. A green build does not renew an old verdict.
Step 5 names the only two exceptions, both for commits that answer a verdict.

The brief is the PR's own claims, not its diff summary. Write it per
[BRIEF](BRIEF.md), which is the part that decides whether a verdict is worth
anything, and size it per [the agents README](../../agents/README.md): about
25 tool calls, verdict-bearing steps first, and "mark anything unreached
*insufficient coverage*".

Never the authoring session's own context. If this session wrote the PR, that
is exactly why the reviewer is a subagent: the author's verification is a claim
to falsify, not evidence.

### 4. Post the verdict, then let the policy decide the ending

One comment per verdict: the verdict, the head it judged, each finding with its
evidence, and what the reviewer did not reach. Then resolve `mergePolicy` once
(`bin/llmctx explain mergePolicy`, or the key in `.llmctx.json`, default
`hold`) and act on it, exactly as [grab](../grab/) does:

- **`hold`** — stop. Say which PRs are ready and which have findings.
- **`review-and-merge`** — for a `CLEAN` verdict: confirm it names the current
  head, wait for required CI on that same head, merge, then clean up by the global guidelines' §5
  rules. A finding goes back to its author through fix → re-review, never a
  quiet patch; step 5 bounds that loop. If `gh pr merge` is refused by a permission rule, say so and
  fall back to `hold` out loud; a refusal is not a verdict on the work.
- **`queue`** — say which are ready, with verdicts, and stop.

A `DO-NOT-MERGE` verdict is never merged under any policy.

### 5. Fix rounds, and where they stop

"Every fix is re-reviewed" has no end of its own. On 2026-11-14 two branches
ran five and six full re-review rounds; severity fell each round and the
finding count did not, because a full review of a changed diff always finds
another edge case. The rule stays. What is bounded is the scope and budget of
each re-review, and the stop is said out loud before the first one runs.

A **round** is one fix commit and one narrow re-review of that commit. The
fix commit answers every defect in the verdict before it, so a verdict with
three defects still starts one round, not three. There are at most three
rounds.

1. **Say the stop condition before starting**: defects are fixed, in at most
   three rounds; anything else is recorded and not fixed in this PR. A defect
   is wrong behaviour, a claim the change makes that is false, or a step two
   readers would act on differently. A preference about wording, style or
   structure is not one.
2. **A fix gets a narrow re-review, not a new full review.** A fresh `reviewer`
   is briefed with the fix commit's own claims and only that commit's diff, and
   told to look one door over from the fix. Budget 15 tool calls in the first
   round and fewer in each later one.
3. **Stop at `CLEAN`.** A preference, or a finding that belongs to another
   slice, is recorded by name as an accepted note or as a follow-up issue. It
   does not start a round. Every verdict, full or narrow, is posted as its own
   comment naming the head it judged, and the note goes in that comment; it
   goes in the PR body only where this session authored the PR.
4. **A test gap found by a narrow re-review is a tests-only commit.** It is not
   a round and gets no re-review.
5. **If the third round's re-review still finds a defect, stop and tell the
   owner.** No fourth fix is made and the PR stays `DO-NOT-MERGE`. The change
   is not converging, and whether to continue, split it or rethink it is their
   decision.

Every one of these commits moves the head. Once a PR has a verdict, what the
new head needs depends on what was pushed since that verdict:

| commits since the last verdict | how the new head is judged |
|---|---|
| only the fix answering a `DO-NOT-MERGE` | the narrow re-review above, not a full review, though step 1 would call the PR reviewable |
| only a tests-only commit from item 4 | no review: required CI on the new head, then a comment naming that head and the `CLEAN` it carries forward |
| anything else, including a merge of the base branch or a fix pushed with unrelated work | a full review, by step 3's head rule |

The first two rows are the only exceptions to step 3's head rule. A narrow
`CLEAN` closes the verdict its fix answered, because that fix answered every
defect in it; a fix that left one unanswered is not `CLEAN`, whatever the
re-review of its diff says. Stopping the loop is not a decision to merge: that
is still `mergePolicy`, in step 4.

## Rules

- Triage before reviewing. A review of a conflicted or held PR is waste.
- One PR, one brief, one reviewer. Never one brief covering two PRs.
- Keyed on the head SHA: an unchanged head is not re-reviewed.
- The reviewer reports; it never edits, pushes, merges or comments itself.
- Never merge a `DO-NOT-MERGE`, and never merge on your own verification.
- A fix is re-reviewed narrowly, every time; the loop stops at `CLEAN` (step 5).
- If an independent reviewer is unavailable, report insufficient coverage and
  hold the PR. Do not substitute the authoring session or install a tool merely
  to satisfy the named workflow.

## Related

- [start-a-session](../start-a-session/) names the merge queue as a seam and
  dispatches here.
- [grab](../grab/) owns the same `mergePolicy` ending for a single branch.
- [triage](../triage/) is the issue-side equivalent; its "argue the other side"
  step is where the case-against discipline comes from.
