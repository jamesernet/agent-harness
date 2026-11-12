---
name: start-a-session
description: Open a working session — read local git state, the tracker and the merge queue, name the two or three seams that actually want attention, then hand off to the skill that fits. User-invoked as /start-a-session [nudge].
argument-hint: "[nudge: tickets | architecture | docs | ux | merge-queue]"
disable-model-invocation: true
---

# Start a session

The opening motion of a working session, made repeatable: look at what is
half-finished locally, glance at the tracker and the merge queue, decide which
two or three things deserve this session, then start the right kind of work.
It is not a dashboard. It ends in a call, and then it acts on the call.

Why it exists: three worktrees held finished, tested, unpushed work and a
fourth held a whole skill staged and never committed, and the only reason any
of it surfaced is that someone happened to run a cleanup pass. This skill is
that look, taken every time a session opens, before anything is picked.

## Procedure

### 1. Assess — read-only, cheap signals, this repository only

Four probes. Nothing here writes. Nothing here is a deep audit:
[docs-drift-audit](../docs-drift-audit/) is a *destination* in step 3, not a
probe here, because a full drift audit on every session start is the cost
that gets a skill abandoned.

1. **Stranded work.** `bin/worktree.sh status --json` (agent-harness; a repo
   that ships its own helper names it in its CLAUDE.md/AGENTS.md). Read the
   `headline` per row — `STRANDED`, `DIRTY`, `DIVERGED`, `UNKNOWN` — and
   `prSource`: `gh-missing` or `gh-failed` means the PR column is *unknown*, not
   empty; `gh-truncated` means the first page was full and unlisted branches were
   looked up one by one. The default `gh` limits are 30 issues and 30 PRs, which a
   busy repository exceeds; the limits above are deliberate.
2. **Tracker.** `gh issue list --state open --limit 200 --json number,title,labels,assignees,updatedAt`
   into three buckets: `ready` and unassigned (grabbable); open and unlabelled
   (untriaged); `ready` but untouched for weeks (suspect — the premise may have
   moved since it was written).
3. **Merge queue.** `gh pr list --state open --limit 100 --json number,title,baseRefName,mergeStateStatus,reviewDecision,isDraft`.
   What this session may do with those PRs is the repository's call: resolve
   `mergePolicy` (`bin/llmctx explain mergePolicy`, or the key in
   `.llmctx.json`, default `hold`) and say which it is when offering the
   merge-queue seam, because it decides whether that seam ends in a review or
   in a merge.
   Flag `CONFLICTING`, approved-and-unmerged, and a child PR whose base branch
   has since merged — nothing retargets it for you.
4. **Policy and doc drift.** `bin/llmctx repo diff . --json` where the repo is
   harness-aware: `STALE`, `MISSING`, `CONFLICT`. A declared `OVERRIDE` is a
   position, not drift.

Then one concurrency check: count the other live sessions holding this repo
(`ps -eo pid,args` filtered to a command of exactly `claude` or `claude .`,
then `lsof -a -p <pid> -d cwd -Fn`). **Report the count and the cwds, nothing
more.** Process age and file mtime both lie about idleness, so never say a
session is stuck or idle, and never propose a worktree for a branch one of
those cwds already holds.

Treat the result as a snapshot. A repo with several live sessions moves while
you read it; re-read the one row you are about to act on in step 3.

### 2. Name at most three seams

For each seam: one line of what, one line of evidence (a row from step 1, by
name), and **one clause of the case against acting on it now**. The case
against is not decoration — a call made without it is a hunch, which is why
[triage](../triage/) argues the other side before promoting a ticket. One
clause, not a section: this is a live conversation, not an issue body.

Which signal means which seam, and the usual case against each, is in
[SEAMS](SEAMS.md). Cap it at three. If more qualify, the rest are one sentence:
"also seen, not proposed: …". The failure mode of this skill is becoming a
status board.

**The nudge.** `/start-a-session architecture` jumps to that seam; which seams
each nudge value narrows to is the last table in [SEAMS](SEAMS.md) (`tickets`
covers all three tracker seams, and step 3 still asks). Step 1 still runs in
full. The stranded-work check is the one step that must not be skippable; both
findings that motivated this skill had existed for weeks and surfaced only
because someone looked.

### 3. Offer, then apply

One `AskUserQuestion`, two to four options, one marked recommended with a
one-line tradeoff. Then invoke the chosen skill **in the same turn**. The
dispatch table is in [SEAMS](SEAMS.md); every destination is an existing
skill or a documented command.

Two rules on the hand-off:

- **A fan-out is a batch of sessions, not a batch inside one session.**
  [grab](../grab/)'s rule holds: one grab = one branch = one worktree = one
  brief. With several grabbable issues, prepare one worktree per issue and hand
  back the list of sessions to open, named `<repo> @ <branch>` — or dispatch
  the managed `implementer` agent, which already runs in its own worktree.
- **Outward-facing steps stay behind the one yes.** Creating a worktree,
  pushing a stranded branch, commenting on an issue: only after the pick, and
  every one of them named in that single question. Nothing in step 1 or 2 has
  written anything, and nothing in step 3 writes what the question did not say.

## What this adds over asking cold

The squash-merge-correct stranded-work proof (`git merge-base --is-ancestor`
reports "not merged" about every correctly squash-merged branch; `status`
proves against the merged PR's head instead); a hard cap of three seams, each
carrying its case against; and a dispatch that respects no-batching instead of
fanning work into one session.

## Rules

- Step 1 writes nothing. Step 3 writes only what the one yes named.
- Never claim a session is idle or stuck; report cwds and a count.
- Three seams, each with its case against. More is a status board.
- If nothing qualifies, say so in one line and stop. Do not invent a seam.

## Related

- [handoff](../handoff/) is the other end of a session: compact what this one
  learned for the next. Start here, end there.
- [review-merge-queue](../review-merge-queue/) is where the merge-queue seam
  goes when it is the pick: it triages the queue before spending a reviewer on
  it, and `mergePolicy` decides whether a clean verdict ends in a merge.
- [grab](../grab/) · [triage](../triage/) · [to-issues](../to-issues/) ·
  [improve-codebase-architecture](../improve-codebase-architecture/) ·
  [docs-drift-audit](../docs-drift-audit/) · [interview-me](../interview-me/)
