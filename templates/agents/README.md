# Agent profile templates

Shells for Claude Code subagent definitions. Copy one into a project's
`.claude/agents/<name>.md` (or an account's `~/.claude/agents/`), then deepen it
against the work it is actually doing.

**STATUS: shells.** Each file has the right shape and enough substance to be
useful on the first run, and none of them has been hardened against a real
engagement yet. They are deliberately thin — a profile written before the work
is a guess, and a guess that reads as settled is worse than an empty file.

## Why these exist separately from skills

A **skill** is a procedure: load it and follow the steps. A **profile** is a
point of view: who is looking, what they are tuned to notice, and what they will
refuse to do. The same codebase reviewed by the QA profile and the business-owner
profile returns two different lists, and that is the point.

Where a profile's job overlaps a skill that already exists, the profile says so
and defers. `ux-designer` does not reimplement `product-ux-review`.

## The shape

```yaml
---
name: kebab-case              # this is the subagent_type you dispatch to
description: when to use it   # the dispatcher matches on THIS, so write it as
                              # trigger conditions, not as a job title
tools: Read, Grep, Glob       # omit to inherit everything; narrow for read-only
model: sonnet                 # omit to inherit the parent's model
---
```

Then: what it is for, what it is **not** for, how it works, and what it returns.

The `description` field does the most work and is the one most often written
badly. "A UX design expert" routes nothing. "Use when auditing an implemented
interface for interaction defects, or when a layout needs a design read before
it ships" routes correctly.

## The profiles

| profile | tuned to notice | writes? |
|---|---|---|
| [systems-architect](systems-architect.md) | decisions that are expensive to reverse | no |
| [ux-designer](ux-designer.md) | interface and interaction quality | no |
| [qa-nitpicker](qa-nitpicker.md) | the case nobody wrote a test for | no |
| [devops-engineer](devops-engineer.md) | build, deploy and observability paths | builds, never deploys |
| [small-business-owner](small-business-owner.md) | cost, time, and "what do I actually get" | no |

Four of the five are read-only on purpose. A profile is a reviewer; when it
starts editing, its findings stop being independent of the thing it is judging.

## House rules these inherit

Profiles do **not** restate the voice, behavioural, or communication rules — those
live in `global/` and reach an agent through the installed adapters. A profile
that re-states them creates a second copy free to drift. Say only what is
specific to the point of view.

One rule is worth repeating inside a profile rather than inheriting, because it
is a hard boundary rather than a preference: **an agent builds and checks, it
never deploys.** See `devops-engineer.md`.
