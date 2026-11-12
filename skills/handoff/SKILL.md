---
name: handoff
description: Compact the current conversation into a handoff document for another agent to pick up.
argument-hint: "What will the next session be used for?"
disable-model-invocation: true
---

Write a handoff summarising the current conversation so a fresh agent can continue the work.

**Where it goes is the repo's call, so read `docs/agents/workflow.md` if `setup-skills` has been run here, else the repo's CLAUDE.md/AGENTS.md first.** Two shapes are in use. Where the repo keeps handoffs in the tree, write `docs/briefs/handoffs/<yyyy-mm-dd>-<slug>.md` and delete it once the next session has absorbed it. Where the repo has retired that path — some gitignore it so it cannot come back — **a mid-flight handoff is a comment on the ticket**: what you did, what you were about to do, and what you learned the ticket does not already say. Do not create a directory the repo does not already use; that is how a retired mirror comes back. If there is no repo at all (a non-code session), fall back to the OS temporary directory.

This is for **session-to-session continuity** of work you're already carrying — not for distributing a unit of work to someone else, and not where requirements live. If you're handing a task to another agent or person to own, write an agent brief on the issue instead (see the `triage` skill's `AGENT-BRIEF.md`) and keep the durable requirements there. A handoff doc points at those artifacts; it does not replace them.

Include a "suggested skills" section in the document, which suggests skills that the agent should invoke.

Do not duplicate content already captured in other artifacts (PRDs, plans, ADRs, issues, commits, diffs). Reference them by path or URL instead.

Redact any sensitive information, such as API keys, passwords, or personally identifiable information.

If the user passed arguments, treat them as a description of what the next session will focus on and tailor the doc accordingly.

The next session opens with [start-a-session](../start-a-session/), which reads the tracker and the worktrees rather than a handoff file — so put what it cannot see (what you were about to do, and what you learned) on the ticket, and leave what it can see out.
