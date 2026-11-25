---
name: close-out
description: Close out working sessions in the current or explicitly selected repositories — inspect worktrees, preserve authorized work and ticket handoffs, list what the current session learned that is recorded nowhere, and report what still needs attention. User-invoked as /close-out.
disable-model-invocation: true
---

# Close out sessions

Sweep the requested repositories before their sessions close. Preserve the reasoning
that Git cannot save, using the existing worktree status and handoff conventions.
This reports session readiness; it does not close windows or perform cleanup.

[handoff](../handoff/) is for one ticket, mid-flight: the work continues and
the next session needs what the ticket does not say. Close-out is for the end
of a session, across everything the session touched; it uses handoff for any
ticket still in flight.

## 1. Take a read-only snapshot

Default to the current repository. If the user names several roots, inspect
those roots; if they explicitly request the registered estate, read the existing
global registry with `git config --global --includes --get-all llmctx.repo` and
include the current root. Treat entries as paths, never shell code. Do not
silently expand to unregistered directories. Name unreachable roots and missing
registry access as coverage gaps; a partial sweep cannot certify every session.
Respect work-context/provider boundaries: coordination does not authorize
private content access, account switching, or writes through another identity.

Repeat the remaining steps per selected repository. Keep its tracker, policy,
and approvals separate from the others.

Read the repository's AGENTS.md/CLAUDE.md and workflow instructions. Use its
worktree helper; in agent-harness, `bin/worktree.sh status --json`. Include
branches without a checked-out worktree. Check the tracker and PR state where
available; never invent a ticket from a branch name.
If no helper is available, report plain Git worktree/branch/status metadata and
the missing PR or merge-proof coverage. Do not install a helper or source an
`.envrc` to make the sweep work.

For each `STRANDED`, `DIRTY`, `DIVERGED`, or `UNKNOWN` row, name what is local,
what is committed, and what remote evidence exists. A matching local tracking
ref alone is not a fresh remote check. Use a matching current PR head, an
observed successful push, or a read-only remote-head lookup before claiming
remote preservation. A missing/failed/truncated PR lookup is unknown, not no PR.

Report dirty and untracked work as unpreserved by Git, not as files that vanish
when a window closes. Report live session names/cwds only when known. A clean
tree, an old process, or an unchanged mtime does not establish that another
session is idle or that its reasoning is captured.

## 2. List what the current session learned

Preserved work is not the whole of a session. Ask what this session learned or
decided that the repository, the tracker and the agent's memory do not already
say. Only the current session can answer for itself; do not write this list
for another session.

Check each candidate against where it would live before keeping it. An item
already on the ticket, in a commit or PR body, or in a document is dropped,
not restated. **An empty list is a normal result: say "nothing to capture" and
move on.** Do not write documentation to mark the end of a session.

Give each remaining item exactly one home:

| what it is | home |
|---|---|
| where in-flight work stands, and what comes next | a comment on its existing ticket, via [handoff](../handoff/) |
| shipped behaviour or a convention changed and a document still says the old thing | an edit to that document; find the lines with [docs-drift-audit](../docs-drift-audit/) scoped to the files this session touched, not the whole repository |
| work found and not done | a follow-up issue, where the repository tracks work that way |
| durable guidance on how to work here, of use to later sessions | the agent's memory, where the tool has one |

A decision that should outlive the work follows the repository's own decision
record convention. Something that fits no row stays in the report.

These are proposals. They join step 3's list and need the same authorization
as any other write; a read-only close-out request reports them and makes none.

## 3. Propose exact preservation actions

List the branch, ticket/PR, and action. Reuse authorization already given for
those actions and targets in this session; ask only for missing authorization
or a material change in scope. A read-only close-out request grants no pushes
or tracker writes by itself.

- Push only already-committed work on an authorized branch with a verified
  ticket or PR. Do not commit unfinished work merely to preserve it; an
  unfinished SKILL.md committed here becomes an installable skill.
- For a branch without a ticket or PR, report the local state and leave it.
  Do not create a tracking issue or remote branch just to make the report green.
- Write handoffs only to existing tickets where authorized, using
  [handoff](../handoff/) and the repository's placement rules. Include the next
  action, useful reasoning, verification limits, and artifact pointers that
  the ticket does not already contain. Working notes stay local.
- Only the current session knows its own uncaptured reasoning. For another
  session, request its owner's summary when needed or mark the handoff unknown;
  never reconstruct an internal decision from file timestamps or a clean diff.

## 4. Perform only the approved actions

Before acting, re-read the relevant row and head. If another session changed it,
reassess the proposal; do not overwrite its work. Read the required Git workflow
reference named in the tool adapter before Git state changes. Use normal pushes;
report a rejection without force or a policy override.

After a handoff, stop implementation on that ticket. Finish only the remaining
approved close-out actions and report. Keep credentials, account details, and
private configuration out of public ticket comments.

## 5. Report what can close

Use `<repo> @ <branch>` and the worktree path when no session name is available.
Separate observed committed/pushed/reviewed/merged state from activation and
publication. Planned actions and an unverified check are not completed actions.

Report the capture list: what was written and where, what was proposed and
not approved, and what was dropped as already recorded.

Name the sessions ready to close only when their disk state is preserved and
their current reasoning is captured or confirmed by the owner. For other
sessions, say what remains unknown. Keep deferred authentication, deployments,
and device activation deferred; close-out does not reopen them.

Never remove a worktree, delete a branch, merge a PR, or install configuration
as part of this skill. Those are separate workflows and authorizations.

## Related

- [start-a-session](../start-a-session/) reads the same repository state at opening.
- [handoff](../handoff/) defines the per-ticket continuity artifact.
- [docs-drift-audit](../docs-drift-audit/) finds the document lines a change left behind.
