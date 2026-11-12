# Briefing a reviewer for one pull request

The brief decides whether a verdict is worth anything. Nine adversarial
reviews on 2026-11-11 produced findings in proportion to how specific their
brief was, and the two that hit the turn limit without reporting were the two
written as "review this PR".

## The contract

**The PR body is the falsification target, not the summary.** A body that
claims "measured on git 2.56: outside a repository, exit 128" is an assertion
with a reproduction attached. Quote the claims and say *falsify these*. A
reviewer told to "look for problems" produces the generic findings that get
skimmed.

**Name the failure class that matters here**, from the diff's subject:

| the PR touches | the dangerous class | the class that gets it switched off |
|---|---|---|
| a guard or hook | a wrong answer with exit 0 on the action it exists to catch | a false positive on ordinary work |
| an installer | silently skipping a step, or overwriting what it does not own | refusing a machine that is actually fine |
| a reporting tool | reporting success about a place it did not look | a finding a mature repository must learn to ignore |
| a skill | a step that writes before the one yes; two agents reading it differently | — |

**State the budget, in the brief.** About 25 tool calls. Put the
verdict-bearing steps first and number them, so a reviewer that runs out has
still answered the question. End with: *mark anything unreached "insufficient
coverage"*.

**Ask for mutation evidence, not agreement.** "Revert the fix in a scratch
copy and name the test that fails" is checkable. "Looks correct" is not.

**Say what is out of scope**, with the ticket that owns it, or the reviewer
spends its budget on a known limitation and reports it as news.

## The shape

```
Adversarial review of <repo> PR #<n>, branch <b>, head <sha>, worktree <path>.
Read only: modify nothing, no git mutations, no GitHub writes, fixtures under
$(mktemp -d) only. HARD BUDGET: 25 tool calls.

The change: <two sentences>. `gh pr view <n>` has the claims table — falsify it.
<The dangerous class for this subject, named.>

1. Run <the suite>.
2. <The probe that would expose the dangerous class>, as a table of input → result.
3. Mutations, in a scratch COPY: (a) … (b) … — which test message fails for each?
4. Lint, portability, and <anything the author claimed but could not verify>.

Report: verdict first (`CLEAN` or `DO-NOT-MERGE`), then the table, then findings
ranked by severity with command, observed, expected, and regression-versus-main
or pre-existing. State what you did not reach. Evidence only, no rewrites.
```

## Reading the verdict

- A `CLEAN` with no "insufficient coverage" line is a claim about the **whole**
  brief. Read it as one, and check the brief was the right brief.
- A finding goes back to the PR's author through fix → re-review. The second
  review of a fix is not optional: on PR #99 the first fix for a reviewer's
  finding had the same hole one door over, and on PR #83 three consecutive
  fixes each introduced the next defect.
- A reviewer that stopped early is asked for its verdict on the evidence it
  has, not read out of its transcript.
