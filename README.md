# agent-harness

Portable, versioned defaults for how my coding agents work across machines and repositories.

This repository is the source of truth for global behavior, communication style, portable Claude safety settings, shared skills, third-party skill pins, Git safety hooks, and intentionally public brand context. Project-specific instructions remain in each project. Personal permissions, machine-specific identities, credentials, and application setup remain in the workstation repository.

## What this solves

- The same core rules reach Claude Code and Codex without maintaining two independent copies.
- A new machine can install a known release and verify its state.
- Repositories can declare a small committed policy while retaining local overrides.
- Shared skills are installed as versioned copies, so moving or deleting this checkout does not break them.
- Local drift is visible through deterministic commands rather than agent interpretation.
- Public content publication is separate from local agent installation.

The boundary is deliberate: `agent-harness` owns portable agent behavior; a project owns its local context; `workstation` owns machine setup and private values.

### Why the CLI is still called `llmctx`

This repository was named `llm-context` until [ADR-001](https://github.com/jamesernet/agent-harness/issues/21). The name under-described
what it holds, so it was renamed; the acronym was left alone on purpose.

`llmctx` is a protocol identifier, not a label. It appears in Git config keys,
`.llmctx.json`, `.llmctx-managed.json`, the `llmctx:begin`/`llmctx:end` mirror
markers, the `llmctx-hook` marker in installed Git hooks, and consumers'
`.llmctx-version` pins. Those strings are compared for equality by tooling that
is already installed in other repositories and on other machines, so renaming
them would not be a rename — it would be a migration, with a window in which
every consumer reads as unmanaged. The acronym stays frozen.

The same reasoning keeps `LLMCTX_SKILL_MANAGED_BY` at `jamesernet/llm-context`;
`bin/lib/skills.sh` says so at the line itself.

Architecture decisions are recorded as issues titled `ADR-NNN`, not as files
here — see [ADR-001](https://github.com/jamesernet/agent-harness/issues/21) and [ADR-002](https://github.com/jamesernet/agent-harness/issues/22). `AGENTS.md` says why.

## Quick start

Prerequisites are Git, Bash, jq, and either `shasum` or `sha256sum`. macOS and Linux are supported.

```sh
git clone https://github.com/jamesernet/agent-harness.git
cd agent-harness
./install.sh
bin/llmctx doctor
```

Installation generates the global adapters, merges the managed Claude settings, installs versioned skill copies for Claude and Codex, and installs this repository's Git hooks. It does not publish website content or initialize other repositories.

For normal workstation automation, check out an intentional `vMAJOR.MINOR.PATCH` tag before running `install.sh`; do not track a floating `main`.

## Daily commands

```sh
bin/llmctx version [--json]
bin/llmctx install [--account <name>]
bin/llmctx doctor [--json|--quiet] [--account <name>]
bin/llmctx repo diff [repo] [--json]
bin/llmctx explain <profile|branchPolicy|protectedBranches> [repo]
bin/llmctx account list [--provider claude|codex] [--json]
bin/llmctx account add [--provider claude|codex] <name> <dir>
bin/llmctx account remove [--provider claude|codex] <name>
bin/llmctx skills install [--dev] [--bundle <name>] [--account <name>]
bin/llmctx agents install [--dev] [--account <name>]
bin/llmctx context apply <profile.toml> [--check]
bin/llmctx vendor check
bin/llmctx publish sync [--check]
```

Use `doctor` for machine-level state. Use `repo diff` inside a project to compare that repository with the standard. Both are read-only and return non-zero when required attention is found. JSON output is intended for workstation automation.

`skills install` uses managed copies by default. `--dev` is an explicit development mode that links directly to this checkout so skill edits take effect immediately.

`--bundle` narrows what lands in `~/.claude/skills` to a named group from [`skills/bundles.conf`](skills/bundles.conf) — `core`, `website`, `webapp`, `platform`, `fintech`, or several comma-separated. The default is `all`, so existing installs are unchanged.

Narrowing here is the only thing that makes skill selection real. A project's own `.claude/skills/` is **additive** and cannot hide a globally installed skill, so until the global set is reduced every project sees everything. The choice persists in `git config --global llmctx.skillBundle`; without that, the next `llmctx install` would silently widen it back to `all`. `llmctx doctor` reports the active bundle, so "absent on purpose" stays distinguishable from "install went wrong".

Selection is per Claude account. `llmctx.skillBundle.<account>` overrides the global key for that account, so a machine running a regulated backend under one account and marketing sites under another does not have to share one answer — and a plain `llmctx install` no longer re-applies one account's choice to the others. Registered Codex homes follow the global key; the older bundle-key namespace is not provider-qualified, so sharing Claude overrides would be ambiguous.

An unknown bundle name is refused and changes nothing — resolving it to the empty set would prune every installed skill over one missing letter.

## Provider accounts

Claude Code keys its credential store by `CLAUDE_CONFIG_DIR`, so a second config directory is a second, fully independent login rather than a swapped token — which is how one machine works across two organizations while connectors and Remote Control keep working in both.

Register each extra directory once; `install` and `doctor` then cover all of them:

```sh
bin/llmctx account add acme ~/.claude-acme
bin/llmctx install
bin/llmctx doctor
```

Codex homes use the same registry shape with an explicit provider:

```sh
bin/llmctx account add --provider codex acme ~/.codex-acme
```

This makes installation and drift checks cover that home without copying its
credentials or authenticated session. `CODEX_HOME` selects the home at launch;
authentication isolation must still be proven with independent real logins on
the adopting machine before relying on it as a security boundary.

`~/.claude` and `~/.codex` are always installed into as `default` for their provider and cannot be unregistered. Registration is purely additive, because a list that could omit the primary would reintroduce exactly the failure this exists to prevent: an install that skips a config directory and still reports success. `--account <name>` remains a Claude-only narrowing flag for compatibility; a normal run checks every registered home.

Each account gets its own `hooks/`, so no account depends on another's directory surviving. An account created by copying another arrives holding the original's hook paths; `install` re-points them rather than leaving both wired.

`account remove` unregisters a directory. It never deletes one — dropping a credential store as a side effect of a config change is not a trade this tool makes for you.

**`account` is not `profile` or `context`.** A *profile* (`personal` / `client`) describes repository policy. A *context* describes a work identity and security boundary. An *account* describes which provider login a session runs on. Different axes, deliberately different words.

**Routing a repository to an account** is direnv's job, not this tool's, since it is the shell that has to carry `CLAUDE_CONFIG_DIR` into `claude`. Put the `.envrc` one level ABOVE the repositories so it covers all of them:

```sh
# ~/repos/github.com/<org>/.envrc
export CLAUDE_CONFIG_DIR="$HOME/.claude-acme"
```

A repository with its own `.envrc` needs `source_up_if_exists` as its first line, or it shadows the parent entirely — silently, with no error — and the routing does not apply there. Confirm with `/status` in a live session; it names the account and org.

**The backstop for that routing** is `hooks/account-guard.sh`, installed into every account like the branch guard. Declare which tree belongs to which account, once, in global git config:

```sh
git config --global --add llmctx.accountRoute acme=~/repos/github.com/acme
```

A write under a routed path from any other account is refused at the first tool call, with the fix in the message. Routes-only and symmetric: an unrouted path is nobody's business, so the client account can still edit a personal repo. It fails fast rather than early — quota is consumed by model calls and a hook runs after the first one — so it is a tripwire, not a billing boundary. Suspend it deliberately with `touch <config-dir>/.allow-cross-account`; `llmctx doctor` reports the routes and refuses one that names an unregistered account.

## Data flow

```text
global/ ───────────────> <claude-home>/CLAUDE.md
       └───────────────> <codex-home>/AGENTS.md
claude/settings.json ──> <claude-home>/settings.json (portable keys merged)
bin/claude-hooks/ ─────> <claude-home>/hooks/
skills/ + vendor/ ─────> <claude-home>/skills/ and <codex-home>/skills/
agents/ ──────────────> <claude-home>/agents/
brand/ ── explicit ────> existing publication repositories
```

Default homes and every registered provider home are covered by a normal install.

`AGENTS.md` is the canonical project instruction file. A project's `CLAUDE.md` should import it with `@AGENTS.md`, avoiding two drifting project rule sets.

Generated global adapters and portable managed settings are never edited as their source. Change files here, rebuild with `llmctx install`, and verify with `llmctx doctor`. Settings that identify private tools or grant personal permissions belong in a private machine configuration; the merge preserves keys this repository does not declare.

Those `@import` lines are paths, not content, and Claude Code says nothing when one does not resolve — the session simply runs without those rules. `llmctx doctor` checks that every direct import exists and names the one that does not.

## Environments

A project declares what it needs to run and deploy, by name, in the same
`.llmctx.json` it already commits:

```json
"environment": {
  "target": "cloudflare-pages",
  "cloud": { "awsProfile": "acme-readonly", "awsRegion": "us-west-2" },
  "secrets": ["CLOUDFLARE_API_TOKEN"]
}
```

`targets/<name>.conf` describes a *kind* of destination; adding one is adding a
file. The declaration names identifiers and environment variable NAMES and
nothing else, and the validator enforces that on **every** field rather than on
`secrets` alone: cloud values must be plain identifiers, tools and MCP servers
plain names, and any string anywhere in the block that carries a scheme, a
host, or a known credential shape is rejected. A vault path or an SSO start URL
here would be a client identity map in a repository that client can read.

```sh
bin/llmctx env check [repo]      does what this repo declares resolve here?
bin/llmctx env explain [repo]    the declaration, and what is still manual
```

`check` is read-only: no network, no credentials, and it never sources
`.envrc`, because sourcing would run arbitrary repository code during a check.
It verifies resolution, not validity — whether a profile still has working
credentials only using it can tell you, and finding that out is a deploy.

What it does not do is judge whether an identifier is the *right* one. A profile
name that resolves may still be the wrong account; only the human who granted it
knows. The validator keeps credentials out and the checker says what is missing.

Where a value comes from is layered, lowest to highest: the target file, the
repository's declaration, then the machine's binding in `workstation`. Claude
account routing is orthogonal and the environment layer never sets it.

There is no writer here, deliberately, for the same reason there is no
repository-init command: `project-scaffold` writes, this reports.

## Repository policy

Projects may commit `.llmctx.json`:

```json
{
  "schemaVersion": 1,
  "profile": "client",
  "protectedBranches": ["main", "stage"]
}
```

Resolution order is repository-local Git config, committed policy, global Git config, then built-in defaults. A `client` profile defaults to `deny`; `personal` defaults to `remind`. Local overrides stay local:

```sh
git config llmctx.branchPolicy off
bin/llmctx explain branchPolicy
```

### A second tenant on the same ladder

`mergePolicy` (`hold` by default, or `review-and-merge`, `queue`) says what a
session may do with a pull request it has finished. It is read by skills rather
than hooks — it governs what a session chooses, not what it is stopped from
doing — and it does not change the rule that nothing pushes or opens a pull
request without being asked.

```sh
bin/llmctx explain mergePolicy
git config llmctx.mergePolicy review-and-merge
```

`irreversiblePolicy` takes the same four values through the same four tiers, and
judges the **action** rather than the branch it happens on: force push, hard
reset, history rewrite, force branch deletion, remote branch deletion, and a
recursive delete whose target resolves outside the repository. The hook is
`<account>/hooks/irreversible-policy.sh`.

```sh
bin/llmctx explain irreversiblePolicy
git config llmctx.irreversiblePolicy deny
```

Two things differ from `branchPolicy`, both deliberate. The default is `ask`
**everywhere** rather than derived from the profile, because branch strictness
genuinely is a dial a client engagement turns up, while "stop and confirm before
destroying something" is the same answer in every repository — and a
profile-derived default would have made the personal case `remind`, which for a
destructive command means warning once and allowing every one after it. For the
same reason `remind` is treated as `ask` here.

What it does not check matters as much. Database drops and migrations against a
non-local environment are named in the guidelines and are not recognisable from
a command string without guessing which connection string points where.
`git rebase` and `commit --amend` are the ordinary way to tidy a branch before
review. A push or pull request opened without being asked has no mechanism here,
because its stage is a `pre-push` hook this repository does not have. A guard
that is wrong on ordinary work gets switched off, and then it protects nothing.

There is intentionally no repository-init command. `llmctx repo diff` reports missing conventions and exact remediation without modifying an external repository. See [repository policy](docs/repository-policy.md) for the schema, precedence, statuses, and adoption workflow.

## Skills and provenance

Owned skills live in `skills/`; third-party skills live in `vendor/`. The catalogue — what each skill focuses on, what it adds over asking the model cold, how to use one without installing the rest, and which ones lean on tools outside this repository — is [`skills/README.md`](skills/README.md). Every installed copy contains `.llmctx-managed.json` with its source path, release or revision, and content hash. The installer updates or prunes only marked copies and known development links. An unrelated real directory is preserved as a conflict.

`vendor.lock.json` records the full upstream commit, selected skills, and deterministic content digest. Vendor updates require an explicit tag or commit:

```sh
bin/update-vendor.sh <tag-or-commit>
bin/llmctx vendor check
```

Floating `main`, `master`, and `HEAD` are rejected.

Managed subagent definitions live in `agents/` and install into every Claude account's `agents/` with the same ownership contract, recorded in a sidecar `.llmctx-managed.json` because an agent is one file rather than a directory. They give the subagents skills spawn a default model, effort and turn budget that travels with the work, which no hook can set after the fact; a caller can still override per invocation. See [`agents/README.md`](agents/README.md) for the set and the tiering. Codex has no subagent format and gets none.

## Safe multi-agent work

Never build directly on `main` or `master`. A single session may use a feature branch in its checkout. Concurrent sessions should use one worktree per branch:

```sh
bin/worktree.sh new feature/example
bin/worktree.sh ls
bin/worktree.sh status          # what is in flight: dirty, unlanded, PR, merge proof
bin/worktree.sh rm feature/example
```

`status` is read-only and exists because finished work was invisible: it reports, per worktree and per branch with commits not yet on a protected branch, the dirty state, the commits, the upstream, the pull request for the branch and — when that PR has merged — whether this tip is what merged (`merged-exact`, `merged-ancestor`) or has moved past it (`diverged`). The line that matters is `STRANDED`: commits and no pull request. `--json` gives a skill the same report. It deletes nothing and suggests nothing.

Briefs and handoffs live on the issue tracker, which is the source of truth: the brief is the issue, and a mid-flight handoff is a comment on it. A repository that wants a committed mirror keeps `docs/briefs/README.md`, which is what the policy checker expects by default; one that does not declares `"briefs": "tracker"` in `.llmctx.json`, as this repository does. Commits should be logically scoped, use a clear subject of at most 72 characters, and omit `Co-authored-by` trailers. Nothing pushes or opens a PR without an explicit request.

Once a local branch is proven merged into `main` or `stage`, an agent may remove its clean worktree and delete the merged local branch with the safe Git checks documented in the global guidelines. It never force-deletes or removes a remote branch as part of that cleanup.

## Publishing

Local installation never touches website repositories. Publication is explicit:

```sh
bin/llmctx publish sync
bin/llmctx publish sync --check
```

Normal sync skips consumer repositories that are not cloned and never creates repository roots. Check mode treats missing repositories and marker-block drift as failures. Content intended to remain private does not belong in `global/`, `brand/`, or any published target.

## Work-context profiles

`templates/work-context.example.toml` is the canonical shape for an identity and security boundary. It supports path precedence, public Git identity, explicit provider bindings, projects, environments, and secret-manager references. `templates/client-profile.example.toml` remains as a compatibility example.

**The pattern lives here; the instances live in `workstation`** (`config/contexts/<id>.toml`, private to that machine). Same split as everything else in this repo — agent-harness owns the reusable form, the consuming repo owns the content.

Two ideas carry most of the value:

- **One enforcement dial.** `level = "low" | "standard" | "high"` expands into branch policy, signing, secret scanning and push policy, because that is how the decision is actually made — "this client has real auditors", not twelve independent switches. Explicit keys still override it.
- **An `[ai]` section.** `agents_allowed` and `allow_code_egress` record whether you are contractually permitted to run an agent against a client's code. That question has real consequences in regulated work, and nothing else on the machine encodes the answer.

Path resolution uses longest-match precedence, so an organization default can be overridden by one repository without changing the context ID later.

**Executable slice.** `bin/llmctx context apply <profile.toml> [--check]` renders the `[providers.claude]` model policy — `account`, `models`, `max_effort` — into that account's `settings.json` as `availableModels`, `enforceAvailableModels` and `maxEffortLevel`, touching nothing else, with a drift check. `client apply` accepts the older `[ai]` shape as a compatibility alias. WorkStation owns generation of identities, path indexes, and provider registries.

## Teams

`templates/teams/` holds copyable multi-persona packs with their own runtime, as
against the single-file profiles in `templates/agents/`. The first is
`templates/teams/opinion-gallery/`: four or five AI personas read a
news feed on an org's behalf, stay quiet by default, draft when one has a
strong opinion, debate once when two flag the same story, and hand the result
to a person as a drafts directory and a GitHub Issue. It is model-agnostic
(any OpenAI-compatible endpoint, a local model, or the Anthropic SDK) and it
never publishes. The pattern lives here; a real org's contract lives in its
own repo. See `templates/teams/opinion-gallery/README.md`.

## Layout

```text
global/       portable behavioral, communication, and handoff rules
claude/       portable Claude safety settings
targets/      hosting-target descriptions for environment declarations
skills/       owned skills
agents/       managed subagent definitions (model, effort, turn budget)
vendor/       pinned third-party skills
templates/    copy-into-project starters: agents, work contexts, teams
brand/        intentionally public personal-brand context
bin/          stable CLI, installers, checks, hooks, and libraries
tests/        deterministic shell tests and portable runner
docs/         detailed operating references
```

## Development and releases

```sh
bin/lint-skills.sh
bin/check-vendor-lock.sh
tests/run.sh
pre-commit run --all-files
```

CI runs the portable suite on Ubuntu and macOS and the full quality hooks on Ubuntu. Release tags must match `vMAJOR.MINOR.PATCH` and point exactly at the tested commit. `llmctx version --json` exposes the tag, full revision, and dirty state for automation.

See [operations](docs/operations.md) for installation ownership, diagnostics, updates, publication, release steps, and recovery guidance.

## License

Original code, skills, and documentation are available under Apache-2.0.
Personal material under `brand/` is reserved, and third-party content retains
its upstream terms. See [LICENSING.md](LICENSING.md) for the exact boundary.
