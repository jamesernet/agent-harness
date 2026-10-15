# Publication boundary

`agent-harness` is designed to be public. It contains portable agent behavior,
reusable skills, safety hooks, policy schemas, and personal-brand content that is
already published to websites. It must not become a convenient aggregation point
for client or workstation secrets.

## Data flow and trust boundaries

```text
public contributors/upstreams
            |
            v
      agent-harness source ---- tagged release ----> local agent configuration
            |                                            ^
            | explicit publication                       |
            v                                            |
      public websites                         private workstation overlay
                                                 + project-local context
```

The important crossings are untrusted contribution to executable agent context,
public source to a privileged local installation, and private overlays merged
with public defaults.

## Rules

- Personal permissions, credentials, account identifiers, client profiles, and
  private repository names stay in `workstation` or project-local configuration.
- `global/`, `brand/`, examples, tests, and documentation are public by design.
- `claude/settings.json` declares only portable safety settings. Its installer
  preserves keys supplied by a private machine overlay.
- Third-party skills are pinned by commit and content hash in
  `vendor.lock.json`; updates are explicit and reviewed as executable guidance.
- Releases are immutable inputs to workstation automation. Consumers install a
  tested tag, never a floating branch.

## Ranked threats

| Threat | Boundary | Class | Risk | Mitigation | Status |
|---|---|---|---|---|---|
| Credential or client data enters Git history | private to public | Information disclosure | High | pre-commit secret scanning, CI, narrow examples, private workstation overlay | Mitigated |
| Malicious skill or installer change reaches a privileged machine | contributor to install | Tampering / elevation of privilege | High | reviewed changes, pinned releases, tests, vendor hashes; protect `main` when visibility changes | Pending GitHub control |
| A mutable upstream silently changes installed guidance | upstream to vendor | Tampering | High | immutable upstream commit plus verified content digest | Mitigated |
| Public defaults overwrite private local configuration | public to private overlay | Tampering | Medium | recursive merge owns only declared top-level keys; tests preserve private keys | Mitigated |
| Documentation exposes the names or controls of private client systems | private context to public docs | Information disclosure | Medium | generic examples and publication review | Mitigated |

Revisit this boundary when a new source can write agent configuration, a new
publication target is added, or a release begins executing code from another
unverified source.

## Visibility-change checklist

- Complete a current-tree and full-history secret scan.
- Confirm the repository license and preserve all third-party notices.
- Enable private vulnerability reporting.
- Enable branch protection or a repository ruleset requiring the portable and
  quality CI jobs on `main`.
- Confirm `workstation` remains private and pinned to a tested release.
- Change repository visibility, then update the website copy that describes it
  as private.
