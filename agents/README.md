# Agents

Managed Claude Code subagent definitions. Installed into every registered
account's `agents/` by `bin/install-agents.sh` (`llmctx agents install`), with a
sidecar `.llmctx-managed.json` recording what is managed, so an agent file you
add by hand is preserved and a managed one is updated or pruned. Codex has no
subagent format, so nothing is installed there.

## Why these exist

A skill that spawns subagents otherwise spawns them on the session model at the
session effort. Three reviewers for one essay on the largest model at the
highest effort is the kind of spend nothing decides on purpose. Pinning the
model, effort and turn budget in an agent file is the only enforceable control:
hooks can observe a subagent start but cannot change its model.

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
- Skills that are judgment end to end declare `effort:` in their frontmatter so
  they never run below it whatever the session is set to: `threat-model`,
  `tech-due-diligence`, `money-movement-review` at `xhigh`. Procedure-shaped
  work declares a lower floor: `site-visual-baseline` at `medium`.

A skill that should run entirely inside a subagent uses `context: fork` plus
`agent: <name>` in its frontmatter. None do today: every skill in this set has a
judgment step that belongs in the caller's context.

## Tuning

Change the file here, run `llmctx agents install`, and `llmctx doctor` reports
the copy current. If `scout` returns thin results on a large codebase, move it
to `sonnet` before widening its turns. Valid `model` values are `sonnet`,
`opus`, `haiku`, `fable`, `inherit`, or a full model id; `bin/lint-skills.sh`
checks the frontmatter.
