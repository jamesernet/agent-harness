# vendor/

Third-party skills, vendored so the setup is reproducible. Not authored here
— don't edit in place; update wholesale with `bin/update-vendor.sh <tag-or-commit>`.
The machine-readable full commit and content hash live in `vendor.lock.json`.

Installed into `~/.claude/skills/` and `~/.codex/skills/` by
`bin/install-skills.sh`, same as `skills/`.

## Contents

| skill set | source | pinned commit |
|---|---|---|
| web-perf | [cloudflare/skills](https://github.com/cloudflare/skills) `skills/web-perf` | `cbf893b954222276bf1af57e5f23379231e0efb9` |

Only `web-perf` is vendored: it is the one Cloudflare skill a bundle installs
(`website`, and therefore `webapp`), and it is vendored so Codex receives it
too. The rest of the set was vendored for a `cloudflare` bundle no account
activated, while the Cloudflare plugin keeps the full current set in
`~/.claude/skills` by itself — see issue #36 for the decision. When that plugin
writes the same upstream commit this pin names, `install-skills.sh` adopts the
identical directory (writes the marker) rather than reporting a conflict; a
newer upstream still surfaces as a conflict, which is the cue to re-pin.
