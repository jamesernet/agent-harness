# OKF Knowledge Format

Use this write path when the repo uses an OKF knowledge bundle. Discover its
location from project instructions and existing docs (including
`docs/agents/domain.md` when present); `docs/knowledge/` is a default, not a
migration requirement. Unlike a flat CONTEXT.md, concept documents may explain
behavior, interfaces, lifecycles and source relationships.

Use [repo-knowledge](../repo-knowledge/SKILL.md) to establish or substantially
expand a library. Its [authoring profile](../repo-knowledge/references/authoring-profile.md)
and pinned validation kit provide the shared OKF mechanics. Existing repos may
have a different declared version or profile: preserve their conventions unless
migration is part of the request.

## Writing a resolved concept

- Find and refine the existing concept instead of creating another home for
  the same term. Create a new concept only when the idea has no existing home.
- Define what the term means in this context and explain relevant behavior.
  Source code, schemas and policies remain authoritative; cite rather than
  duplicating their mutable values or entire definitions.
- Attribute supported claims through `sources[].resource` and stable source
  IDs, with matching Markdown footnotes. Use ordinary contextual links for
  relationships between concepts and to existing decisions.
- Record actual authorship in `generated`, explicit lifecycle status, and the
  profile's descriptive fields. Do not invent a human verifier or preserve an
  old review as current after changing the content. `timestamp` is legacy
  metadata, not a replacement for provenance and trust fields.
- Add index links so the concept is discoverable from the bundle root through
  area indexes. The root index may declare `okf_version`; nested index.md and
  log.md files have no frontmatter. Do not label indexes as Concept documents.

Update an entity map only when the repository already maintains one. Do not
require new architecture maps, principles documents or test matrices merely to
add a term. Architecture decisions and their rationale follow the repository's
ADR convention, including tracker-based ADRs; do not create a duplicate file.

Known unanswered domain questions can be explicit draft gap concepts using the
repo-knowledge profile. Ephemeral work plans and implementation TODOs remain on
the tracker or in local working notes, not in the durable concept library.
