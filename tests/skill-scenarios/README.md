# Skill decision scenarios

These probes check what an agent chooses next when it reads the actual skill
against a fixed user request and observed state. They cover four skills and
eleven situations: prior publication approval, deferred activation, missing
reviewers, review-head changes, unchanged verdicts, deferred authentication, and
unavailable reproduction evidence, authorized close-out, unfinished skills,
unknown reasoning in another session, and incomplete registered-estate coverage.

Prepare a prompt without its answer key:

```sh
python3 tests/skill-scenarios/evaluate.py prompt /tmp/grab-probe.txt --skill grab
```

Give a fresh agent that prompt and only its named skill files. Ask it to return
the specified JSON. Save its unedited response outside the repository, then:

```sh
python3 tests/skill-scenarios/evaluate.py check /tmp/grab-outcomes.json --skill grab
```

Repeat for `review-merge-queue`, `diagnosing-bugs`, and `close-out`, or omit `--skill` to prepare
the full set. Keep the source commit, provider/model, prompt, unedited response,
and scorer result with the local run evidence. Report which cases failed and
inspect the free-text reasons before changing a skill; a failed score can expose
an ambiguous case as well as a bad instruction. Re-run changed cases with fresh
context. Never show the evaluator the expected outcomes first.

CI runs the deterministic fixture/scorer tests, including deliberately prohibited
actions, unsupported completion claims, and malformed results. It does not call
a model. Model probes are explicit, opt-in runs; this script does not launch an
agent, use credentials, or perform any of the scenario's actions.

A passing probe demonstrates a decision on this snapshot. It does not prove
that a live workflow executes that decision, enforces a permission boundary, or
generalises to other models and prompts. Keep command-level integration tests
for execution behavior and report their results separately.
