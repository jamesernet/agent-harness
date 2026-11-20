---
name: repo-knowledge
description: Build or maintain a source-backed OKF knowledge library in a repository, including industry terminology, business and customer knowledge, code architecture, internal components, and explicit knowledge gaps. Use for establishing or expanding a reusable knowledge base, not ordinary documentation edits or speculative SEO promises.
---

# Repository Knowledge

Create a useful, navigable knowledge library whose claims can be traced to evidence.
OKF is the portable file format, not a publishing strategy, search-ranking signal,
knowledge-graph service, or replacement for the code and policies it describes.

## Establish the authority and audience

Read the repository instructions, existing knowledge and domain docs, tracker,
branch/worktree state, manifests, entrypoints, schemas and tests before choosing a
layout. Check whether the checkout is behind its intended integration branch;
state which revision you actually inspected. Follow the repository's existing
tracker and documentation conventions rather than creating a second brief or ADR.

Determine who consumes the library and whether it is private, public, or mixed.
Keep internal material outside public/static routes. Metadata is not access
control: publishing a repository or serving a folder publishes its contents.
Public export or runtime UI is separate work unless explicitly requested.

Reuse an existing knowledge root; otherwise default to `docs/knowledge/`. Organize
by the questions readers ask, usually industry, business, customers, platform,
operations and governance. Add folders only when useful content warrants them.
See [the authoring profile](references/authoring-profile.md) for the formats and
source conventions. Domain terminology work can use [domain-modeling](../domain-modeling/SKILL.md).

## Research and build

- Inventory existing facts and their owners. Inspect architecture, stack and
  internal components from code now; do not leave these as empty templates when
  evidence is available. Identify data flow, interfaces, failure behavior and
  compatibility constraints that affect someone changing the system.
- Source standard industry terminology from primary organizations, standards
  bodies, regulators and official documentation. Define terms in original words;
  cite the source and its applicable context. General trade knowledge does not
  establish that this business offers a service, holds a credential, or follows
  a process. Research law, incentives, prices and standards afresh when relevant.
- Separate evidenced customer types from proposed segments. Capture intent,
  constraints and journey where supported; do not invent demographic or sales
  knowledge from a form field or a page title.
- Keep canonical business facts, runtime definitions, policies and schemas where
  they already live. A concept explains their meaning and points to authority;
  it does not become another manually maintained source for mutable values.
- Write a concept per useful idea, with contextual links to related concepts.
  Each directory index provides short descriptions and links into its children;
  the root index supplies starting paths for common tasks. Avoid a giant glossary
  dump or one document per source page.
- Record genuine unknowns as explicit draft gaps with concrete questions and
  evidence needed. Ask only about gaps that affect the requested outcome; the
  rest become a useful owner intake list. Never fill them with plausible facts.
- Keep generated attribution honest and leave `verified` absent until a real
  verification occurs. Schema checks do not verify facts. Lifecycle and review
  status are separate; preserve the difference between code, deployed behavior
  and owner-confirmed operating practice.

## Validate and make it maintainable

Copy [assets/validation](assets/validation/) into an appropriate repository-local
scripts directory when the library needs independent CI. The kit contains a
verbatim upstream OKF v0.3 validator, Apache license, immutable commit/checksum
manifest and a thin local profile checker. Its [requirements](assets/validation/requirements.txt)
pin PyYAML; install them in the repository's chosen Python environment, never by
silently changing a global environment.

```sh
python3 -m pip install -r scripts/okf/requirements.txt
python3 scripts/okf/check.py docs/knowledge
python3 scripts/okf/check.py docs/knowledge --json --now 2026-11-20T12:00:00Z
```

Adapt the copied directory path to the repo. Use its existing CI job and dependency
conventions; do not rename protected checks or add a new framework unnecessarily.
Run the repository's required checks and inspect representative source claims and
navigation manually. The checker reports stale knowledge informationally and never
writes verification metadata. Report what was inspected and what remains unknown.

Link the library from authored project instructions or an existing documentation
entry point. If an instruction file is generated, change its actual source rather
than the generated adapter. Do not impose unrelated architecture maps, scenario
matrices, or ADR files as a prerequisite.

## Maintain and update

When new evidence arrives, find the existing concept before creating another.
Resolve conflicts against the declared authority; retain disputed claims as
unknown rather than choosing whichever wording is convenient. Cite the evidence,
update `generated` for meaningful content changes, and do not carry forward a
review as current when it predates the changed content. Link deprecated concepts
to replacements rather than breaking existing links.

Code-source URLs should identify the inspected commit, with readable local paths
for finding current authority. For offline folders or missing remotes, use real
local evidence rather than invented URLs; the authoring profile describes a
minimal source-snapshot fallback when portability is needed. A new unrelated commit does not invalidate every
concept: review concepts whose relevant evidence changes. Set `stale_after` where
a calendar review is useful and capture ownership in prose when known; do not
invent owners or schedule upkeep without a request.

To update the validation kit, select a deliberate immutable upstream commit,
inspect its SPEC and validator changes together, replace upstream files verbatim,
preserve licensing, refresh the manifest/checksums and fixture tests, then review
the copied repository kits separately. Do not fetch mutable upstream code during
validation or silently rewrite consumer repositories.
