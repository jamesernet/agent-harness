---
name: close-out
description: Close out a repository's working sessions — inspect worktrees, preserve authorized work and ticket handoffs, and report what still needs attention. User-invoked as /close-out.
disable-model-invocation: true
---

# Close out sessions

Sweep the current repository before its sessions close. Preserve the reasoning
that Git cannot save, using the existing worktree status and handoff conventions.
This reports session readiness; it does not close windows or perform cleanup.

## 1. Take a read-only snapshot

Read the repository's AGENTS.md/CLAUDE.md and workflow instructions. Use its
worktree helper; in agent-harness, `bin/worktree.sh status --json`. Include
branches without a checked-out worktree. Check the tracker and PR state where
available; never invent a ticket from a branch name.

For each `STRANDED`, `DIRTY`, `DIVERGED`, or `UNKNOWN` row, name what is local,
what is committed, and what remote evidence exists. A matching local tracking
ref alone is not a fresh remote check. Use a matching current PR head, an
observed successful push, or a read-only remote-head lookup before claiming
remote preservation. A missing/failed/truncated PR lookup is unknown, not no PR.

Report dirty and untracked work as unpreserved by Git, not as files that vanish
when a window closes. Report live session names/cwds only when known. A clean
tree, an old process, or an unchanged mtime does not establish that another
session is idle or that its reasoning is captured.

## 2. Propose exact preservation actions

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

## 3. Perform only the approved actions

Before acting, re-read the relevant row and head. If another session changed it,
reassess the proposal; do not overwrite its work. Read the required Git workflow
reference named in the tool adapter before Git state changes. Use normal pushes;
report a rejection without force or a policy override.

After a handoff, stop implementation on that ticket. Finish only the remaining
approved close-out actions and report. Keep credentials, account details, and
private configuration out of public ticket comments.

## 4. Report what can close

Use `<repo> @ <branch>` and the worktree path when no session name is available.
Separate observed committed/pushed/reviewed/merged state from activation and
publication. Planned actions and an unverified check are not completed actions.

Name the sessions ready to close only when their disk state is preserved and
their current reasoning is captured or confirmed by the owner. For other
sessions, say what remains unknown. Keep deferred authentication, deployments,
and device activation deferred; close-out does not reopen them.

Never remove a worktree, delete a branch, merge a PR, or install configuration
as part of this skill. Those are separate workflows and authorizations.

## Related

- [start-a-session](../start-a-session/) reads the same repository state at opening.
- [handoff](../handoff/) defines the per-ticket continuity artifact.
