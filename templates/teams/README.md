# Teams

Copyable packs of several personas that work together, each with a contract
people write and a small runtime that runs it. Copy a whole directory into the
org's repo; the pattern lives here, the instance lives there.

This is the other half of `templates/agents/`. A profile there is one point of
view, one file, copied into `.claude/agents/` and run inside Claude Code. A
team here is several voices, a brief they all read, rules on how they argue,
and code that schedules them; it runs on its own and inherits nothing from
`global/`.

| team | what it does | runtime |
|---|---|---|
| [opinion-gallery](opinion-gallery/) | personas read a feed, draft when one has a strong opinion, debate once, hand to a person | Python, uv |

A team never publishes, deploys, or merges. It produces something a person
reviews.
