# Repository policy

`.llmctx.json` is a small committed declaration of repository intent. It does not contain machine paths, identities, credentials, or client secrets.

## Schema

```json
{
  "schemaVersion": 1,
  "profile": "personal",
  "branchPolicy": "remind",
  "irreversiblePolicy": "ask",
  "protectedBranches": ["main", "master"],
  "briefs": "tree",
  "claudeImport": true,
  "strandedExempt": ["backup/"],
  "mergePolicy": "hold"
}
```

All fields except `schemaVersion` are optional. Profiles are `personal` or `client`. Branch policies are `off`, `remind`, `ask`, or `deny`. `protectedBranches` must be a non-empty array of non-empty strings.

`mergePolicy` resolves through the same four tiers as `branchPolicy`, and `llmctx explain mergePolicy` reports which one answered. Its value is shape-validated, unlike `briefs` and `claudeImport`, because a misspelling should be heard from `repo diff` rather than silently ignored by the skill meant to obey it.

`irreversiblePolicy` takes the same four values and governs actions that cannot be undone rather than the branch they happen on: force push, hard reset, history rewrite, force branch deletion, remote branch deletion, and a recursive delete whose target resolves outside the repository. Two things differ from `branchPolicy` on purpose. Its built-in default is `ask` for **both** profiles, because "stop and confirm before destroying something" is the same answer in a personal repository and a client engagement, where branch strictness genuinely is a dial. And `remind` is treated as `ask`, because reminding once that a destructive command is destructive and then allowing every one that follows protects nothing.

What it does not check is as deliberate: database drops, migrations against a non-local environment, `git rebase`, `git commit --amend`, and opening a pull request without being asked. The first two are not recognisable from a command string without guessing which connection string points where; the next two are the ordinary way to tidy a branch before review; the last has no mechanism here, since its stage is a `pre-push` hook this repository does not have.

## Declarable conventions

Two checks are positions a repository may reasonably take the other side of. Both default to the stricter value, so a repository that says nothing is checked exactly as before; declaring the choice turns a `MISSING` into an `OVERRIDE`.

`briefs` is `tree` (default) or `tracker`. `tree` expects `docs/briefs/README.md`. `tracker` says the narrative lives on the issue tracker and there is deliberately no mirror in the repository — *a brief that restates its ticket is worse than no brief, because it is a second copy to drift.*

`environment` is optional. It declares the hosting target, cloud identifiers,
secret NAMES, tools and MCP server names a project needs — never a value and
never a vault reference. The validator constrains every field, not only
`secrets`: cloud values must be plain identifiers, tools and MCP names plain
slugs, and any string carrying a scheme, a host or a known credential shape is
rejected wherever it appears in the block. `target` must
name a file in `targets/`. `llmctx env check` reports whether the declaration
resolves on this machine; `llmctx env explain` prints it with the steps that
remain manual.

`claudeImport` is `true` (default) or `false`. `true` expects a `CLAUDE.md` whose body is `@AGENTS.md`. `false` says the repository is deliberately tool-neutral and keeps `AGENTS.md` alone.

`mergePolicy` is `hold` (default), `review-and-merge`, or `queue`. It says what a session may do with a pull request it has finished, and it is the first key on this ladder that **no hook reads**: it governs what a session chooses, not what it is stopped from doing, so its readers are skills. It does not change the rule that nothing pushes or opens a pull request without being asked — it decides what happens once that has been asked for.

| value | what a session does with a green pull request it authored |
|---|---|
| `hold` | records the review on it, says it is ready, stops |
| `review-and-merge` | dispatches a **fresh** reviewer, never its own authoring context, with the PR body's claims as the brief; merges only on a clean verdict, after CI, then cleans up by the §5 rules; a finding goes back through fix and re-review |
| `queue` | a named owner or a merge queue merges; the session says it is ready and moves on |

`hold` is the default for both profiles. A merge is the one step in the flow where a person in the loop costs least and protects most, so the cautious answer is what a repository gets for saying nothing; the other two are a committed decision with a diff rather than a sentence in a chat log. Note that `review-and-merge` needs a per-project permission rule allowing `gh pr merge` as well: the policy says what should happen, and the rule is what lets it.

`strandedExempt` is a list of branch-name prefixes, empty by default. `bin/worktree.sh status` reports a branch with commits past a protected branch and no pull request as `STRANDED`; a prefix listed here (for example `backup/`, for branches kept on purpose and never meant to merge) suppresses that headline for branches that start with it. The row is still reported, so nothing is hidden; only the judgement is withheld. It is read by `worktree.sh` alone and is not shape-validated, like the two keys above.

These exist because both were being reported against repositories that had chosen otherwise on purpose, and a checker a mature repository must learn to ignore is a checker nobody reads.

## Resolution

Values resolve in this order:

1. repository-local `git config llmctx.*` values;
2. committed `.llmctx.json` values;
3. global `git config --global llmctx.*` values where supported;
4. built-in defaults.

The built-in profile is `personal`. Its branch policy is `remind`. A committed `client` profile changes that default to `deny`. Protected branches default to `main master`.

Inspect the effective value and its source with:

```sh
bin/llmctx explain profile
bin/llmctx explain branchPolicy
bin/llmctx explain protectedBranches
```

## Where a repository may live

`sync-location` reports `CONFLICT` when either the working tree or the shared Git directory
resolves beneath a file-sync root: iCloud Drive, `~/Library/CloudStorage`, Dropbox, OneDrive or
Google Drive, including the renamed folders a second linked account produces. `~/Documents` and
`~/Desktop` count only when iCloud's Desktop & Documents option is on.

Both paths are tested because a linked worktree keeps its refs in the shared Git directory, and
those refs are what corrupt. A sync client created collision-duplicate files named `<name> 2`
inside `.git/refs`, `git fetch` then failed with `fatal: bad object refs/heads/... 2`, and the
checkout reported a stale `origin/main` for days with no visible error.

Moving the repository is the fix. `"syncLocation": false` in `.llmctx.json` declares that the
owner accepts the risk, and reports `OVERRIDE` instead, on the same reasoning as `claudeImport`
and `briefs`: a checker a mature repository must learn to ignore is a checker nobody reads.

## Adoption

Run `bin/llmctx repo diff /path/to/repo`. It checks policy resolution, canonical `AGENTS.md`, the Claude import, the briefs convention, Git-hook state, and whether the repository sits under a file-sync root. It does not create or edit anything.

Statuses are:

- `OK`: matches the resolved standard;
- `OVERRIDE`: an intentional repository-local Git override;
- `MISSING`: a required convention is absent;
- `CONFLICT`: policy is invalid, or the repository's location is unsafe for Git;
- `STALE`: an installed managed component differs from this release;
- `UNKNOWN`: another hook framework or foreign component owns the seam. A `project-scaffold` placeholder hook (`scaffold-hook-shim`) is not foreign — it exists to be replaced by `bin/install-git-hooks.sh` — so it is reported `MISSING`, with that command as the remediation.

`MISSING`, `CONFLICT`, and `STALE` make the command non-compliant. `OVERRIDE` and `UNKNOWN` are reported without pretending the tool owns an external framework.

## `core.hooksPath`

When a repository sets `core.hooksPath`, a hook framework owns that seam and `git-hook` is reported `UNKNOWN`. It previously stopped there, and skipped the policy-library check entirely — so a repository with `core.hooksPath` set and no branch enforcement at all printed `Result: compliant`, which is the one output nobody re-reads.

A separate `policy-enforcement` finding now answers the question that actually matters — *is the branch policy enforced anywhere?* — with three outcomes:

- `OK`: hooks in that directory resolve llmctx policy;
- `UNKNOWN`: they check a branch by other means, so the repository is guarded but `.llmctx.json` and `git config llmctx.branchPolicy` are **inert** there;
- `MISSING`: no branch check was found, or the directory does not exist.

The middle case is the common one, and it is the reason the check exists: guarded and unconfigurable looks identical to configured until someone changes `branchPolicy` and nothing happens.
