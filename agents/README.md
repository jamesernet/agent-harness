# Agents

Managed Claude Code subagent definitions. Installed into every registered
account's `agents/` by `bin/install-agents.sh` (`llmctx agents install`), with a
sidecar `.llmctx-managed.json` recording what is managed, so an agent file you
add by hand is preserved and a managed one is updated or pruned. Codex has no
subagent format, so nothing is installed there.

## Why these exist

A skill that spawns subagents otherwise spawns them on the session model at the
session effort. Three reviewers for one essay on the largest model at the
highest effort is the kind of spend nothing decides on purpose. An agent file
is where the model, effort and turn budget get a default that travels with the
work: hooks can observe a subagent start but cannot change its model. A caller
can still override these per invocation, so this is a default, not a cap; a
hard cap belongs in managed settings and is a follow-up.

| agent | model | effort | turns | job |
|---|---|---|---|---|
| `scout` | haiku | — | 25 | enumeration, read-only; lists not judgments |
| `reviewer` | sonnet | high | 40 | unanchored read of code or a diff, evidence per finding |
| `prose-reviewer` | sonnet | high | 10 | one lens of review-prose's three; fixed output contract |
| `implementer` | inherit | inherit | 150 | one slice from a brief in its own worktree, test-first |

Design subagents (codebase-design's design-it-twice) stay on the session model
on purpose: alternative interfaces are judgment work, and a cheaper model there
produces three similar designs instead of three different ones.

## How skills use them

- `review-prose` names `prose-reviewer` for its three parallel passes.
- `improve-codebase-architecture` names `scout` for the exploration walk.
- Skills that are judgment end to end declare `effort:` in their frontmatter.
  It is an override, not a floor: the skill runs at that level whatever the
  session is set to, up or down. `threat-model`, `tech-due-diligence` and
  `money-movement-review` pin `xhigh`, the highest level settings can hold;
  procedure-shaped `site-visual-baseline` pins `medium`, deliberately cheaper
  than most sessions.

A skill that should run entirely inside a subagent uses `context: fork` plus
`agent: <name>` in its frontmatter. None do today: every skill in this set has a
judgment step that belongs in the caller's context.

## Sizing a brief

Measured on 2026-11-11, across nine adversarial reviews of one day's pull
requests. The budgets above are ceilings; the brief decides whether an agent
gets to a verdict inside them.

- **A reviewer brief fits in about 25 tool calls.** `reviewer` has 40 turns,
  and a turn is roughly a tool call. Two briefs that asked for twenty probes,
  three mutations, lint and an install check hit the limit mid-probe and
  produced no report. Two that asked for the same work in a fixed order with
  a hard budget stated in the brief returned verdicts with evidence. State the
  budget in the brief, put the verdict-bearing steps first, and say "mark
  anything unreached *insufficient coverage*".
- **One question per brief; split rather than widen.** A review of a tool and
  a review of the skill that uses it are two briefs. The second reviewer on
  PR #95 covered in thirty calls what the first had not reached in forty,
  because it was asked for exactly that.
- **A fresh reviewer for every merge decision, never the authoring context.**
  Four of today's PRs had a defect introduced by their own fix, and in every
  case it was a reviewer that had not written the fix that found it. The
  authoring session's verification is a claim to falsify, not evidence.
- **A finding goes back through fix → re-review, never a quiet patch.** On
  PR #99 the first fix for a reviewer's finding had the same hole one door
  over; the second reviewer found it because it was asked to.
- **Ask a stalled agent for its verdict; do not read its transcript.** An
  agent that has run long is resumed with one message: "deliver your verdict
  on the evidence in hand; mark the rest insufficient coverage". Both agents
  this was tried on answered within a minute. `TaskOutput` returns the raw
  transcript into the caller's context and is not the tool for this.
- **A verdict names what it did not reach.** A `CLEAN` with "insufficient
  coverage: part B" is a result; a `CLEAN` with no such line is a claim about
  the whole brief, and the caller should read it as one.

## Tuning

Change the file here, run `llmctx agents install`, and `llmctx doctor` reports
the copy current. If `scout` returns thin results on a large codebase, move it
to `sonnet` before widening its turns. Valid `model` values are `sonnet`,
`opus`, `haiku`, `fable`, `inherit`, or a full model id; `bin/lint-skills.sh`
checks the frontmatter.
