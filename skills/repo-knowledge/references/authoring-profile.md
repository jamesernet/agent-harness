# OKF authoring profile

This library profile is stricter than base OKF. The pinned specification is
[OKF v0.3](https://github.com/open-knowledge-format/open-knowledge-format/blob/527e81aff55992be21507e97004286789126f88c/SPEC.md).
The validation kit records the exact upstream files and checksums in `upstream.json`.

## Concepts and sources

Use lowercase hyphenated file names, one useful concept per Markdown file.
Concept documents require non-empty `type`, `title`, `description`, string-list
`tags`, `generated.by` / `generated.at`, explicit `status`, and `sources` under
this profile. Use descriptive types such as Concept, Reference or Playbook;
OKF does not define a closed type taxonomy. Copy and fill the
[concept template](../assets/concept-template.md).

Use stable `sources[].id` values and `sources[].resource`, not `uri`. Attribute
claims with Markdown footnotes keyed to those IDs, including the footnote
definitions needed for ordinary Markdown rendering. Related-concept links convey
relationships through their surrounding prose. Never copy long passages or
standards text into the library.

For code-backed claims, cite an immutable repository URL at the inspected commit
and name the readable local path in the body. Preserve code/schema as authority;
do not duplicate mutable values or entire interfaces. Pinned evidence records a
snapshot, while the local path identifies where a future maintainer checks the
current behavior. In an offline folder or repo without a remote, cite accessible
local artifacts; never invent a repository URL or commit. If the bundle must be
portable, capture only the necessary nonsensitive source assets or exact excerpts
inside it, with a manifest recording original path, capture time and SHA-256 of
the captured bytes (plus excerpt boundaries when applicable). Label these as
snapshots, distinct from current authority; do not copy the whole codebase.
Raw Markdown source can be stored with a `.txt` suffix so it is not misread as an
OKF concept. A public webpage is evidence of published copy, not proof of an
internal operating process or a production configuration.

`generated` records actual authorship and meaningful change time. Use a valid
actor such as `tool-name/version`, `process:identifier`, or `human:identifier`;
never invent a model version or human review. `verified` is optional and records
an actual verification, not successful lint. An older verification is not current
after a meaningful edit. Prefer draft status for new unreviewed synthesis.

## Indexes and gaps

The root `index.md` declares `okf_version: "0.3"`; its remaining content is a
progressive catalogue. Nested `index.md` files and `log.md` have no frontmatter.
Indexes link child concepts or child indexes with concise descriptions. Every
concept and nested index must be reachable from the root through index links;
Each concept is listed by its immediate directory index, and each nested index
is listed by its parent directory index. Ordinary concept cross-links do not
substitute for discoverable index coverage.
Use ordinary inline Markdown links in indexes so readers and validation agree.

A source-free placeholder is allowed only with `status: draft`,
`x-repo-knowledge-gap: true`, and Questions / Evidence needed headings. Use the
[gap template](../assets/knowledge-gap-template.md), state useful questions and
what evidence would resolve them. Do not put unsupported assertions beneath a
placeholder label. The checker validates this structure; a reviewer must inspect
its meaning. Supported draft knowledge still cites its evidence normally.

## Validation boundaries

The checker runs the pinned upstream checks in strict mode and adds this
profile, index target-path/coverage checks, citation-definition checks and case-insensitive
path-collision checks. Staleness is informational. It does not contact source
websites, prove factual correctness, check deployed systems, grant access, or
create human review. URL fragments are not checked against heading anchors.
Review source availability, anchor targets and applicability separately.
