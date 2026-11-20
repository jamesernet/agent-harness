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

**Never work directly on `main`/`master`.** Create a feature branch before changes.
Use a separate linked worktree when sessions may run in parallel, and honor the
repository's worktree helper and hooks. Keep one session per worktree.

**Before changing Git state or cleaning up worktrees, read the Git workflow
reference named in your tool adapter.** It contains the required workspace,
stacking, merge-proof and cleanup procedures. If it is unavailable, stop and
report the missing reference.

Clean up only your own clean, proven-merged worktrees and local branches. Never
force-delete a branch or delete a remote branch without explicit authorization.

## 6. Operating Safety

**Secrets:** Never commit secrets or print credential/env values. If you spot a hardcoded secret or key, stop and flag it — don't "fix" it silently.

**Irreversible actions:** Before `rm -rf`, dropping DBs/tables, running migrations against non-local environments, force-push, history rewrite, or deleting branches — stop and confirm. The only standing exception is deleting a clean local worktree and local branch after the merged-work cleanup checks above prove the branch is fully merged.

**Commits & PRs:** Small, logically-scoped commits, with a subject that describes the commit's overall theme. Keep the subject to a single line that reads comfortably in a terminal; **where a repo has an observed convention, follow that instead** — some write the subject as a claim and legitimately run past 72 characters, and some have their tooling append a PR number you must therefore not type yourself. Add a body only when additional context materially helps the reviewer. Do not add `Co-authored-by:` trailers or other co-author attribution. Never push or open a PR without an explicit ask.
