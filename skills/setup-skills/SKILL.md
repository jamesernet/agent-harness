---
name: setup-skills
description: Configure this repo for the engineering skills — set up its issue tracker, triage label vocabulary, and domain doc layout. Run once before first use of the other engineering skills.
disable-model-invocation: true
---

# Setup Engineering Skills

Scaffold the per-repo configuration that the engineering skills assume:

- **Issue tracker** — where issues live (GitHub by default; local markdown is also supported out of the box)
- **Triage labels** — the strings used for the five canonical triage roles
- **Domain docs** — where the domain language and ADRs live (flat `CONTEXT.md`, multi-context, or OKF), and the consumer rules for reading them
- **Work artifacts** — where a brief and a handoff go, which worktree helper to use, and how a merge is proven in this repo's merge strategy

This is a prompt-driven skill, not a deterministic script. Explore, present what you found, confirm with the user, then write.

## Process

### 1. Explore

Look at the current repo to understand its starting state. Read whatever exists; don't assume:

- `git remote -v` and `.git/config` — is this a GitHub repo? Which one?
- `AGENTS.md` and `CLAUDE.md` at the repo root — does either exist? Is there already an `## Agent skills` section in either?
- `CONTEXT.md` and `CONTEXT-MAP.md` at the repo root
- `docs/knowledge/` (especially an `index.md` with `okf_version` frontmatter) and `docs/architecture/domain-model.md` — signs of an OKF layout
- `docs/adr/` and any `src/*/docs/adr/` directories
- `docs/agents/` — does this skill's prior output already exist?
- `.scratch/` — sign that a local-markdown issue tracker convention is already in use
- `.llmctx.json` — a committed declaration of repository intent, where the repo ships one.
  `briefs` is `tree` (a mirror under `docs/briefs/` is expected) or `tracker` (the narrative
  lives on the issue tracker and there is deliberately no mirror); it answers Section D's
  first question outright. `branchPolicy` (`off`/`remind`/`ask`/`deny`) and
  `protectedBranches` are the declared form of the commit constraint the `.githooks/`
  bullet below otherwise has to infer. Most repos have no such file; that is not a finding.
- `docs/briefs/` — does it exist? Is it **gitignored**? A gitignored path is a deliberate
  refusal, not an absence: check `.gitignore` and `git check-ignore -v docs/briefs`.
  A declared `briefs` outranks both, because it is a statement rather than an inference:
  an absent directory alongside `"briefs": "tracker"` is a decision, not an omission
- `scripts/` and the repo's own docs for a worktree helper (`new-worktree.sh`,
  `prune-worktrees.sh`, or similar) and `.githooks/` + `core.hooksPath` for hooks that
  constrain where a commit may be made from
- the forge's merge settings and the last ~50 subjects on the trunk
  (`git log --format=%s -50`): squash vs merge-commit, whether subjects carry a
  `(#N)` the forge appended, prefix style, and the actual length spread

### 2. Present findings and ask

Summarise what's present and what's missing. Then walk the user through the three decisions **one at a time** — present a section, get the user's answer, then move to the next. Don't dump all three at once.

Assume the user does not know what these terms mean. Each section starts with a short explainer (what it is, why these skills need it, what changes if they pick differently). Then show the choices and the default.

**Section A — Issue tracker.**

> Explainer: The "issue tracker" is where issues live for this repo. Skills like `to-issues`, `triage`, and `grab` read from and write to it — they need to know whether to call `gh issue create`, write a markdown file under `.scratch/`, or follow some other workflow you describe. Pick the place you actually track work for this repo.

Default posture: these skills were designed for GitHub. If a `git remote` points at GitHub, propose that. If a `git remote` points at GitLab (`gitlab.com` or a self-hosted host), propose GitLab. Otherwise (or if the user prefers), offer:

- **GitHub** — issues live in the repo's GitHub Issues (uses the `gh` CLI)
- **GitLab** — issues live in the repo's GitLab Issues (uses the [`glab`](https://gitlab.com/gitlab-org/cli) CLI)
- **Local markdown** — issues live as files under `.scratch/<feature>/` in this repo (good for solo projects or repos without a remote)
- **Other** (Jira, Linear, etc.) — ask the user to describe the workflow in one paragraph; the skill will record it as freeform prose

If — and only if — the user picked **GitHub** or **GitLab**, ask one follow-up:

> Explainer: Open-source repos often receive feature requests as pull requests, not just issues — a PR is an issue with attached code. If you turn this on, `/triage` pulls *external* PRs into the same queue and runs them through the same labels and states as issues (collaborators' in-flight PRs are left alone). Leave it off if PRs aren't a request surface for you.

- **PRs as a request surface** — yes / no (default: no). Record the answer in `docs/agents/issue-tracker.md`. For local-markdown and other trackers, skip this question — there are no PRs.

**Section B — Triage label vocabulary.**

> Explainer: When the `triage` skill processes an incoming issue, it moves it through a state machine — needs evaluation, waiting on reporter, ready for an AFK agent to pick up, ready for a human, or won't fix. To do that, it needs to apply labels (or the equivalent in your issue tracker) that match strings *you've actually configured*. If your repo already uses different label names (e.g. `bug:triage` instead of `needs-triage`), map them here so the skill applies the right ones instead of creating duplicates.

The five canonical roles:

- `needs-triage` — maintainer needs to evaluate
- `needs-info` — waiting on reporter
- `ready-for-agent` — fully specified, AFK-ready (an agent can pick it up with no human context)
- `ready-for-human` — needs human implementation
- `wontfix` — will not be actioned

Default: each role's string equals its name. Ask the user if they want to override any. If their issue tracker has no existing labels, the defaults are fine.

**Section C — Domain docs.**

> Explainer: Some skills (`improve-codebase-architecture`, `diagnosing-bugs`, `tdd`) read the project's domain docs to learn its domain language, plus `docs/adr/` for past architectural decisions. They need to know where that knowledge lives so they look in the right place. The pointers get recorded in `docs/agents/domain.md`; the skills read that file, not a hardcoded filename.

Confirm the layout:

- **Single-context** — one `CONTEXT.md` glossary + `docs/adr/` at the repo root. Most repos are this.
- **Multi-context** — `CONTEXT-MAP.md` at the root pointing to per-context `CONTEXT.md` files (typically a monorepo).
- **OKF** — no `CONTEXT.md`; domain language lives in per-concept docs under `docs/knowledge/` (frontmatter carries `okf_version`) and is indexed by `docs/architecture/domain-model.md`. Also wires in `docs/architecture/principles.md` (enforced principles are treated like ADRs) and `docs/testing/scenario-matrix.md` (test coverage). Propose this if the exploration found those files.

**Section D — Work artifacts and worktrees.**

> Explainer: `grab` and `handoff` have to put a brief and a handoff *somewhere*, and there is no answer that is right in every repo. Some repos commit briefs under `docs/briefs/`; others tried it, watched the copy rot away from the tracker, and now gitignore the path so it cannot come back. A skill that hardcodes either one is wrong half the time — and worse than a rule, because a skill body is an instruction that repo-level precedence never gets to override. The same goes for creating a worktree and for proving a branch merged: under squash merges the usual `git merge-base --is-ancestor` proof can never pass, which leaves the force-delete everyone is told to avoid.

Confirm four things, and **report what the exploration found rather than asking cold** — the repo usually already answers these:

- **Briefs** — on the tracker only (the ticket *is* the brief), or also committed under `docs/briefs/`. Where `.llmctx.json` declares `"briefs": "tracker"`, or `docs/briefs/` is gitignored, the answer is tracker-only: report it rather than offering the choice. Offering a decision the repo has already recorded is how a retired mirror gets recreated.
- **Handoffs** — a comment on the ticket, or a file under `docs/briefs/handoffs/`.
- **Worktrees** — name the repo's own helper if it ships one, and say what its pre-flight is for so nobody skips it. Note any hook that constrains where a commit may be made from.
- **Merge proof and commit subjects** — squash or merge-commit, and the trunk's observed subject convention as a measurement, not a target.

### 3. Confirm and edit

Show the user a draft of:

- The `## Agent skills` block to add to whichever of `CLAUDE.md` / `AGENTS.md` is being edited (see step 4 for selection rules)
- The contents of `docs/agents/issue-tracker.md`, `docs/agents/triage-labels.md`, `docs/agents/domain.md`, `docs/agents/workflow.md`

Let them edit before writing.

### 4. Write

**Pick the file to edit:**

- If `CLAUDE.md` exists, edit it.
- Else if `AGENTS.md` exists, edit it.
- If neither exists, ask the user which one to create — don't pick for them.

Never create `AGENTS.md` when `CLAUDE.md` already exists (or vice versa) — always edit the one that's already there.

If an `## Agent skills` block already exists in the chosen file, update its contents in-place rather than appending a duplicate. Don't overwrite user edits to the surrounding sections.

The block:

```markdown
## Agent skills

### Issue tracker

[one-line summary of where issues are tracked, plus whether external PRs are a triage surface]. See `docs/agents/issue-tracker.md`.

### Triage labels

[one-line summary of the label vocabulary]. See `docs/agents/triage-labels.md`.

### Domain docs

[one-line summary of layout — "single-context", "multi-context", or "OKF"]. See `docs/agents/domain.md`.

### Work artifacts

[one-line summary: where a brief and a handoff go, and the worktree helper]. See `docs/agents/workflow.md`.
```

Then write the three docs files using the seed templates in this skill folder as a starting point:

- [issue-tracker-github.md](./issue-tracker-github.md) — GitHub issue tracker
- [issue-tracker-gitlab.md](./issue-tracker-gitlab.md) — GitLab issue tracker
- [issue-tracker-local.md](./issue-tracker-local.md) — local-markdown issue tracker
- [triage-labels.md](./triage-labels.md) — label mapping
- [domain.md](./domain.md) — domain doc consumer rules + layout
- [workflow.md](./workflow.md) — brief/handoff location, worktree helper, merge proof, subject convention

For "other" issue trackers, write `docs/agents/issue-tracker.md` from scratch using the user's description.

### 5. Done

Tell the user the setup is complete and which engineering skills will now read from these files. Mention they can edit `docs/agents/*.md` directly later — re-running this skill is only necessary if they want to switch issue trackers or restart from scratch.
