#!/usr/bin/env bash
set -euo pipefail

# Where this repository names its owner, enumerated so the list cannot rot.
#
# The repository is public and fork-and-edit. The cost of forking is not that a
# personal identifier appears in the code; it is that nobody can say which of
# those appearances a fork must change, which it may leave, and which one it
# must NOT touch. #55 wrote that list down by hand and it was wrong within two
# months: seven files had gained the identifier that the issue did not name.
#
# So the list is a test. Every tracked file carrying the identifier is listed
# below with what the appearance is for. A file that gains it fails the test
# (the list has rotted forward); a listed file that no longer carries it fails
# too (rotted backward). Either way the fix is to edit THIS file and say why,
# which is the one moment the question "should a fork change this?" gets asked.
#
# The one entry that matters most is bin/lib/skills.sh: LLMCTX_SKILL_MANAGED_BY
# is a protocol identifier compared for equality by every installed copy, and
# changing it de-owns every managed skill on the machine. ADR-001 (issue #21).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "forkability test failed: $*" >&2
  exit 1
}

IDENTIFIER="jamesernet"

# path                                                      what the appearance is, and what a fork does with it
allow=(
  "AGENTS.md"                                                     # ADR links into this repository's issue tracker: a fork retargets or drops them
  "README.md"                                                     # clone URL, ADR links, and the explanation of the frozen marker: a fork edits the URLs, keeps the explanation
  "SECURITY.md"                                                   # security contact: a fork replaces it
  "bin/build-adapters.sh"                                         # GEN_NOTE names the generator so an edited adapter says where to edit instead: a fork renames it
  "bin/git-hooks/pre-commit"                                      # the hook header names its source repository: a fork renames it
  "bin/install-git-hooks.sh"                                      # the default REPOS list: a fork replaces it (the llmctx.repo registry is the per-machine way)
  "bin/lib/skills.sh"                                             # LLMCTX_SKILL_MANAGED_BY -- a fork must NOT change this; see the comment on the line and ADR-001
  "bin/sync-published-context.sh"                                 # SYNC_MAP, which files publish to which website repository: a fork replaces it or empties it
  "skills/README.md"                                              # clone URL: a fork edits it
  "skills/shopify-storefront-review/scripts/storefront-prices.sh" # the User-Agent names the repository: a fork renames it
  "skills/tech-due-diligence/SKILL.md"                            # points at the owner's website repository for playbook templates: a fork edits or drops it
  "targets/cloudflare-pages.conf"                                 # "modelled on" note: a fork may leave it
  "templates/teams/opinion-gallery/src/opinion_gallery/feeds.py"  # the feed reader's User-Agent names the repository: a fork renames it
  "tests/forkability-test.sh"                                     # this file
  "tests/git-hook-test.sh"                                        # asserts the default REPOS entry is skipped when absent: changes with bin/install-git-hooks.sh
  "tests/install-agents-test.sh"                                  # asserts the frozen marker value: must NOT change
  "tests/install-skills-test.sh"                                  # asserts the frozen marker value: must NOT change
)

expected="$(printf '%s\n' "${allow[@]}" | sort)"
actual="$(git -C "$SRC" grep -l -- "$IDENTIFIER" -- . ':(exclude)vendor' | sort)"

# Sites the list does not know about: the list has rotted forward.
unlisted="$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"))"
[[ -z "$unlisted" ]] ||
  fail "files carry \"$IDENTIFIER\" but are not listed in tests/forkability-test.sh -- add each with what the appearance is for:
$unlisted"

# Listed sites that no longer carry it: the list has rotted backward.
stale="$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"))"
[[ -z "$stale" ]] ||
  fail "files are listed in tests/forkability-test.sh but no longer carry \"$IDENTIFIER\" -- remove them:
$stale"

# The entry that matters most is pinned by value, not only by presence.
grep -q 'LLMCTX_SKILL_MANAGED_BY="jamesernet/llm-context"' "$SRC/bin/lib/skills.sh" ||
  fail "LLMCTX_SKILL_MANAGED_BY has changed; see ADR-001 (#21) before touching it"

echo "forkability tests: passed"
