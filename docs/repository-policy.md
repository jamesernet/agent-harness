# Repository policy

`.llmctx.json` is a small committed declaration of repository intent. It does not contain machine paths, identities, credentials, or client secrets.

## Schema

```json
{
  "schemaVersion": 1,
  "profile": "personal",
  "branchPolicy": "remind",
  "protectedBranches": ["main", "master"],
  "briefs": "tree",
  "claudeImport": true
}
```

All fields except `schemaVersion` are optional. Profiles are `personal` or `client`. Branch policies are `off`, `remind`, `ask`, or `deny`. `protectedBranches` must be a non-empty array of non-empty strings.

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
