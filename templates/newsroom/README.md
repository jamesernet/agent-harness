# Persona newsroom

Four or five AI personas read a news feed on an org's behalf. They stay quiet
by default, write a draft in their own voice when one has a strong opinion,
debate once when two or more flag the same story, and hand everything to a
person. Nothing publishes.

The shape borrows from two places: the human-written reviewer contracts in
[agent-review-crew](https://github.com/kbennett2000/agent-review-crew) and the
persona files in [brickfeed-news](https://github.com/kbennett2000/brickfeed-news).
The difference is the register. Brickfeed is satire; this is professional
commentary an org puts its name to after a person has read it.

**STATUS: shells.** Same posture as `templates/agents/`: a persona written
before a week of real feed is a guess, and a guess that reads as settled is
worse than an empty file. Run `--report-only` for a week before enabling
drafts.

## Vocabulary

A **skill** (`skills/`) is a procedure: load it and follow the steps. A
**profile** (`templates/agents/`) is a reviewer's point of view aimed at code;
it runs inside Claude Code and inherits the house rules from `global/`. A
**persona** is a public voice aimed at the news; it runs in its own runtime
and inherits nothing but `guardrails.md`. The word "profile" also names a
repository policy elsewhere in this repo, so the newsroom does not use it.

A **contract** is everything the newsroom reads about one org. People write
all of it. **Stance** is a persona's 0 to 5 judgement of one story: 0 silent
or declined, 1 to 2 noticed, 3 flagged with a reason but no draft, 4 to 5
draft. `draft_threshold` in `config.yml` is the org's dial over that.

## A contract

```text
contracts/<org>/
  config.yml            feeds, provider, thresholds, delivery, who reviews
  shared.md             the org brief every persona reads
  guardrails.md         fixed; prepended to every prompt; hashed by the runtime
  personas/<name>/
    persona.md          who is speaking, what it cares about, what it never does
    knowledge/*.md      optional material only this persona reads
```

The pattern lives here; the instances live in the org's own repo. Two
contracts ship: `starter`, with every blank written `<< like this >>` and an
italic note under each, and `emergentlabs`, a worked example built only from
facts already public in `brand/`. See `docs/publication-boundary.md`: a real
org's feed URLs, reviewers and private knowledge never go in this repository.
`*.local` is already gitignored, so `knowledge/notes.local.md` stays private
in a working checkout.

## The five personas

Each is a question the org's readers ask, not a job title. An org fills in
who, in its world, asks it.

| persona | the question | primary beat |
|---|---|---|
| operator | What does this change on Monday? | BUSINESS |
| skeptic | What is the claim, and what is the evidence? | SCIENCE |
| builder | Is this actually shippable, and by whom? | TECHNOLOGY |
| advocate | Who benefits, and who was not in the room? | CULTURE, LOCAL |
| strategist | Will this matter in five years? | POLICY |

Every persona file has the same sections, in the same order: who is speaking,
what it cares about, what makes it write, how it argues, what it does in a
debate, what it never lets through, and what is not its business. The last
one is the section that keeps a persona quiet, and in a good persona file it
is the longest. Personas do not restate the guardrails or the brief; a second
copy is free to drift.

## Quick start

1. Copy this directory into your repo, for example as `newsroom/`.
2. Copy `contracts/starter` to `contracts/<org>`. Fill `shared.md` first,
   `config.yml` second, then one persona. Leave the others `enabled: false`.
3. Put the key in your environment under the name `provider.api_key_env`
   gives. `.env.example` lists the usual names; copy it to `.env` and fill it.
4. Check, then run without writing anything:

```sh
uv run newsroom check --contract contracts/<org>
uv run newsroom run   --contract contracts/<org> --report-only
```

5. Read a week of flags. Adjust section weights and `draft_threshold`. Then
   drop `--report-only`. Add the second persona only once the first is quiet
   on the right days.

`newsroom bench --persona skeptic --stories fixtures/stories.json` triages one
persona against a fixed story set and prints its stances and reasons, for
tuning a persona file without a live feed.

## API key or local model

`provider.kind: openai` speaks the OpenAI chat-completions shape, which is what
Ollama, LM Studio, vLLM, OpenRouter, Groq and xAI also serve. Point `base_url`
at the endpoint and `model` at the model. For a local Ollama:

```yaml
provider:
  kind: openai
  base_url: http://localhost:11434/v1
  model: llama3.1
  api_key_env: OLLAMA_API_KEY   # any non-empty value; Ollama ignores it
```

`provider.kind: anthropic` uses the Anthropic SDK (`uv sync --extra
anthropic`). `provider.kind: fake` replays `fixtures/fake_replies.json` and is
what the tests use.

Small local models sometimes fail the triage JSON. Lower `feed.max_stories`
first. A failed persona is logged and skipped; the run continues.

## Adapting it

Three deltas, each a change to `config.yml` and `shared.md` plus which
personas flip `enabled`. The code does not change.

**A pet-supplement shop.** Enable operator, skeptic, advocate. Disable builder;
leave strategist off until there is a reason. Weight SCIENCE up for skeptic and
operator (ingredient studies, regulatory notices). "Topics the org never
comments on" gains the health of any named animal and specific competitor
products; a recall the org is party to goes under "already being dealt with".
The skeptic's org-specific hard line: never evaluate a product in the org's
own category. The advocate's readers are pet owners, so its "who pays" is
pricing, subscription terms and returns.

**A VC firm.** Enable strategist, skeptic, builder, operator (its readers are
founders). Disable advocate. Weight BUSINESS and TECHNOLOGY up, LOCAL to 0.
"Never comments on" gains portfolio companies, any named company's fundraise
or valuation, and market direction. Fill "how the org makes money" carefully:
every story about a sector the firm invests in is a possible commercial
interest, and the personas need to say so in their reason.

**A city-level org.** Enable advocate (residents), operator (service
delivery), strategist (planning horizon), skeptic (cost projections). Disable
builder. LOCAL 3 for every enabled persona. "Never comments on" gains
elections and candidates, individual residents, active legal matters and
personnel. "Words it uses and does not": residents, not citizens or users.
Point "Voice" at the city's plain-language guide if it has one.

## Running it on a schedule

`scheduling/github-actions.yml` runs weekday mornings on a GitHub runner,
commits the drafts and state, and opens issues with the runner's own token.
`scheduling/crontab.example` is the same for a machine you own. Both are
copies to adapt, not files the runtime reads.

A cycle costs one triage call per enabled persona, one draft call per flag,
and for each debated story one call per participant plus at most one merge
call. With five personas and two drafts each the ceiling is about 25 calls.

## What it never does

Publishes. Fetches a link. Writes about a tragedy. Names a private individual.
Gives medical, veterinary, legal or financial advice. Claims the org's
position. Writes about the org's own live problem. Runs without a reviewer
named in `config.yml`. Runs with an edited `guardrails.md` unless
`guardrails.modified: true` says so out loud. Ships a real org's contract in
this repository.

## Known limits

A story is identified by its canonical link, so the same event from two
outlets is two stories and two personas only debate when they flag the same
link. Section labels come from the model, against the closed list in
`config.yml`. One debate round, by design.
