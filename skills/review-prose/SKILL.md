---
name: review-prose
description: Review a piece of writing meant for an audience — an essay, field note, landing page, announcement, or README — by running three independent reviewers (a technical editor, a plain-voice editor, and the actual target reader) and synthesizing where they agree. Use when the user asks for a review, edit, critique, or second opinion on something they wrote or are about to publish; when a draft is finished and needs a pass before it ships; when asked whether a piece is publishable, too long, too abstract, or off-voice; or when a review found problems and the fixes need ordering. Not for reviewing code, docs that only describe an API, or a first draft the author is still discovering.
---

# Review Prose

Three reviewers, run independently, then synthesized. The value is not in any one
report — it is in what all three land on without having seen each other.

## Core principle: independence, then convergence

A single reviewer gives you one taste. Three reviewers who cannot see each other's
work give you a signal: when a technical editor, a plain-voice editor, and the target
reader independently name the same passage, that passage is a defect rather than a
preference.

So never run them in one pass, never show one reviewer another's findings, and never
let a reviewer edit the file. They report; you synthesize; the author decides.

The ordering that matters at the end is not severity. It is agreement.

## The context pack

Every reviewer gets the same pack. Skipping it is what produces reviews that argue
with decisions the author already made.

| | What | Why it matters |
|---|---|---|
| **Voice** | The author's voice/style guide, if one exists — in this repository, `brand/voice-and-style.md` | Without it a reviewer proposes hype, jokes, or a chattier register |
| **Format** | The format or template this kind of piece follows | Lets a reviewer judge structure against the intended shape |
| **Exemplar** | A finished piece by the same author | Register and density calibration; catches a templated opener reused across pieces |
| **Intent** | One line: what should the reader do or believe after reading | Reviewers otherwise guess the thesis, and each guesses differently |
| **Audience** | Who this is for, concretely | "Founders at seed to Series B in regulated markets" beats "business readers" |
| **Thesis** | The author's one-sentence claim | Lets a reviewer judge whether the piece delivers it, not whether it is good in general |
| **Decisions** | What is already settled and off the table | Stops a reviewer re-litigating a deliberate choice |
| **Material** | Real stories, numbers, or examples the author is willing to use | Reviewers can say where each one lands instead of only "add a story" |

The decisions ledger and the material inventory are the two that are usually missing
and the two that save a whole round. Ask for them if the user has not offered them.

Reviewers must never invent material. If a reviewer proposes a story, a number, or a
client name, that is a finding to reject, not copy to paste.

## Process

### 1. Assemble the pack

Read the piece yourself first. Gather the eight rows above; mark any you could not
find rather than guessing. If the intent, audience, or thesis is missing and the user
is available, ask — those three change every reviewer's verdict.

### 2. Run three reviewers in parallel

Three agents, dispatched in a single message so they run concurrently and none
can see another's findings. Whatever your agent tool calls that — a general-purpose
subagent, a task, a worker — each one gets the same context pack, is told to
report rather than edit, and is given no path to the others' output. If your
harness cannot run agents, run the three passes yourself in separate turns
without re-reading the previous report: independence is the property that
matters, not the parallelism.

**Technical editor.** Lens: precision, structure, argument integrity. Hunts claims
without support, terms used inconsistently, sections that restate an earlier section,
two frameworks that overlap, tables whose rows contradict the prose, headings that
promise more than they deliver, and anywhere a skeptical expert says "that's not true"
or "so what". Must split findings into *logical or factual errors* versus *stylistic
preference* — that split is what makes the report safe to act on quickly.

**Plain-voice editor.** Lens: does it read like a person talking or like a document?
Hunts abstraction where one concrete sentence would land harder, aphorism stacking
(several quotable lines in a row that start to feel like a slide deck), places the
reader loses the thread, sections that could be halved, whether the opening earns the
next two minutes, and whether the closing line is earned or asserted. Must give a
target length and say where to cut.

**Target reader.** Not an editor. The actual person the piece is for, deciding whether
to trust the author. Answers: do you keep reading after three paragraphs; what is the
one thing you take away and is it what the author intended; where do you nod and where
do you think "easy to say"; would you do anything differently tomorrow; what would you
ask the author on a call; does each artifact (table, diagram, framework) earn its
place; are you more or less likely to hire, buy, or act.

**This third one is the one you cannot skip.** Editors find repetition and structure.
Only the reader finds the piece that is well-built and changes nothing.

### 3. Hold every reviewer to one output contract

- At most 7 findings, ranked.
- Each finding: the exact quoted passage, the problem in one or two sentences, a
  concrete rewrite or cut. Not "tighten this".
- A verdict: publishable as-is, publishable with the top N fixes, or needs a
  structural pass.
- A **keep list**: the passages that must survive any edit. Editors bias toward
  cutting; this protects the lines carrying the voice.
- For the top finding: what would change your mind. Separates defect from taste.
- A word cap. Reports over ~900 words start padding.

### 4. Synthesize; do not relay

Three reports pasted at a user is worse than one. Produce:

1. **Where all three agree.** This is the real finding list, in agreement order.
2. **Logic and factual problems**, from the technical editor, regardless of agreement.
   A contradiction is a defect even if only one reviewer saw it.
3. **What only the reader saw.** Usually the most valuable and the easiest to lose.
4. **Where they conflict**, with your recommendation and the reason. Conflicts are
   normal; leaving them unresolved pushes the work back onto the author.
5. **The decisions the author has to make**, separated from what you can just do.

Then stop and let the author choose. A structural pass on someone's writing without
their agreement is not a review.

### 5. If asked to apply the fixes

Work on a branch. Keep the author's sentences wherever the finding was about structure
rather than wording. Mark anything that needs material you do not have with a comment
in the source's own comment syntax, so it never renders, and say plainly that the piece
is blocked on it.

## Judgment notes

**Convergence is evidence; volume is not.** Three reviewers producing twenty findings
between them with no overlap usually means the pack was thin and each invented a
standard. Re-run with a better pack rather than forwarding the pile.

**Word count is a symptom.** "Cut 40%" is only actionable once you know which sections
restate each other. Get the repetition map first; the cut follows from it.

**A reviewer that only praises has failed.** If a report comes back without a
quotable defect, the prompt was too deferential. Reviewers should be told plainly that
"it's great" is not useful.

**Do not average the reviewers.** Where the plain-voice editor wants a table cut and
the reader calls that table the only thing worth screenshotting, one of them is wrong
about this piece. Say which and why.

**The author's voice outranks every reviewer.** A finding that would make the piece
read like someone else is a finding to decline, and saying so is part of the job.
