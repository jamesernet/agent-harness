# Seams: what a signal means, and where it goes

Read by [start-a-session](SKILL.md) in step 2 (signal → seam, with the usual
case against) and step 3 (seam → destination, with what the hand-off carries).
A seam is a place where one kind of work wants to happen next; it is named by
evidence from step 1, never by taste.

## Signal → seam

| seam | signal in step 1 | the usual case against acting now |
|---|---|---|
| stranded work | `STRANDED`, `DIVERGED`, `UNKNOWN` with commits, or `DIRTY` (anything uncommitted; staged-and-never-committed is the case `git log` cannot show), from `worktree.sh status` | the work may be parked on purpose; pushing it makes a remote branch nobody asked for, and committing an unfinished skill to "save" it ships it under `install --bundle all` |
| ticket hygiene | open issues with no label; `ready` issues untouched for weeks | labelling is not shipping; a `ready` whose premise moved needs re-verifying before anyone grabs it |
| grabbable work | `ready` issues with no assignee, whose premise still holds | the session may be better spent on a seam above it; one grab is one session, so three grabbable issues are not one afternoon |
| a decision to walk | an open `ADR-NNN:` issue, or a decision ticket, still carrying `ready` | a decision ticket closes with a decision, not with work; labelling it `ready` invites someone to do the expensive half by default |
| merge queue | `CONFLICTING`; approved and unmerged; a child PR whose base branch has merged | a held PR is held for a reason recorded on it; read its last comment before touching it |
| blocked on access or a key | an issue naming credentials, account access or a server apply; `env check` failing on a secret *name* | the agent must not hold the credential, so the deliverable is the exact ask to a person, not the unblock |
| sensitive-code review | an open PR touching `bin/claude-hooks/`, `bin/git-hooks/`, `bin/lib/policy.sh`, `claude/settings.json` or `install*` | the author's own session reviewing the author's own guard is how a fix lands wrong one door over; the reviewer must be fresh |
| policy and doc drift | `repo diff` reports `STALE`, `MISSING` or `CONFLICT`; a doc names a path that is not there | a declared `OVERRIDE` is a position the repo took; a checker a mature repo must ignore is a checker nobody reads |

## Seam → destination

| seam | destination | what the hand-off carries |
|---|---|---|
| stranded work, with a ticket or PR | push, behind the one yes; then a handoff comment on the ticket in the [handoff](../handoff/) shape | the `status` row, verbatim |
| stranded work, no ticket | [to-issues](../to-issues/) for the work's own ticket — or an explicit "abandoned" note, so abandoning is a decision rather than a disk event | the row, and which of the two |
| ticket hygiene | [triage](../triage/) | the bucket (unlabelled, suspect) and the issue numbers |
| a decision to walk | [interview-me](../interview-me/) on the issue, then the decision as a comment | the issue, and step 2's case against |
| merge queue | the built-in `/code-review <PR>` dispatched as a fresh reviewer; a stacked child is retargeted with `gh pr edit <n> --base <trunk>` *between* the two merges | PR number, `mergeStateStatus`, the last blocking comment |
| grabbable work | [grab](../grab/) `<issue>` — one worktree per issue; several → a list of sessions to open, or the managed `implementer` agent | issue numbers; never more than one per session |
| blocked on access or a key | a comment on the issue stating the exact action a person must take | the ask, the account, the path |
| sensitive-code review | `/code-review <PR>` as a fresh reviewer, never the authoring session | PR number and the paths touched |
| architecture (nudge) | [improve-codebase-architecture](../improve-codebase-architecture/) | the module or seam the nudge named, if any |
| ux (nudge) | [product-ux-review](../product-ux-review/) | the running URL |
| docs (nudge), or policy drift | [docs-drift-audit](../docs-drift-audit/); `bin/llmctx repo diff` remediation for policy findings | the `repo diff` findings, by id |
| nothing qualifies | one line saying so, then stop | — |

## Nudge → seam

`/start-a-session <nudge>` jumps step 2 to one seam. Step 1 still runs in
full. Where a nudge covers several seams, step 2 names only those, and step 3
still asks.

| nudge | seams it narrows to |
|---|---|
| `tickets` | ticket hygiene, grabbable work, a decision to walk — the three tracker seams; step 3 offers whichever of them step 1 found evidence for |
| `merge-queue` | merge queue, sensitive-code review |
| `architecture` | architecture (the nudge's own seam); stranded work is still named if step 1 found it |
| `ux` | ux (the nudge's own seam) |
| `docs` | policy and doc drift |

## What a seam is not

- A count. "Twelve open issues" is a number; "three `ready` issues nobody has
  touched since the premise changed" is a seam.
- A wish. If no row in step 1 supports it, it is not proposed, however good it
  sounds.
- A batch. Several grabbable issues are several sessions, not one session's
  to-do list.
