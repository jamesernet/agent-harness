# Handoff & Briefs

Where cross-agent work lives, so any agent — Claude Code, Codex, or a human engineer — knows where to look on session start.

- The **issue tracker is the source of truth**, for briefs and handoffs alike. Trackers vary by repo — the repo's own CLAUDE.md/AGENTS.md names which one, and what it calls a ticket that is ready to pick up.
- **An agent brief is the ticket**, not a copy of the ticket. A brief that restates its ticket is worse than no brief, because it is a second copy free to drift.
- **A mid-flight handoff is a comment on that ticket**: what you did, what you were about to do, and what you learned that the ticket does not already say. Then stop.
- **Working notes stay local and uncommitted.** Scratch a plan wherever your agent tool puts temporary files; do not commit it.
- **On session start, read the tracker** — open, unassigned, ready-labelled tickets — before asking what to work on.

**This file no longer prescribes a directory.** It used to mirror briefs into `docs/briefs/` and tell a session to look there first. A global file cannot know whether a repo has adopted that layout, retired it, or forbidden it — core-api retired it on 2026-08-03 after the mirror rotted, and now gitignores the path. A committed briefs directory is still fine where a repo chooses one. **Where a repo says otherwise, the repo wins**, so read the repo before creating a directory for artifacts.

## Routing work

Work items are agent-agnostic; route by the work's shape, not by habit:

- **Claude Code** — default for implementation from a ticket, refactors, reviews, and anything using the skill library (fintech/compliance reviews, triage→PRD→issues pipeline).
- **Codex** — alternate implementer; use for parallel work alongside Claude sessions or as a second opinion on the same ticket. Same tickets, same conventions, prose rules only (no hooks inside the tool — git hooks still apply).
- **Human engineer** — anything requiring judgment the ticket can't encode: ambiguous product calls, credentials/infra access agents shouldn't hold, irreversible migrations. Hand over the ticket, not a chat log.
- **Mid-flight handoff** (any direction): comment on the ticket saying where the work stands, update its status, stop. The next session resumes from the tracker, not from memory and not from a file.
