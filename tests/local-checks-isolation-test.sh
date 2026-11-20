#!/usr/bin/env bash
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-local-checks-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo/bin" "$tmp/repo/tests" "$tmp/git" "$tmp/common"
export CHECKS_FIXTURE="$tmp" CHECKS_REAL_GIT
CHECKS_REAL_GIT="$(command -v git)"
printf '[llmctx]\nclaudeAccount = external=%s/registered-account\n' "$tmp" >"$tmp/global"
cat >"$tmp/bin/git" <<'EOF'
#!/bin/sh
case "$*" in
  'rev-parse --show-toplevel') printf '%s/repo\n' "$CHECKS_FIXTURE" ;;
  'rev-parse --git-dir') printf '%s/git\n' "$CHECKS_FIXTURE" ;;
  'rev-parse --git-common-dir') printf '%s/common\n' "$CHECKS_FIXTURE" ;;
  *) exec "$CHECKS_REAL_GIT" "$@" ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/pre-commit"
for tool in lint-skills.sh check-vendor-lock.sh; do
  printf '#!/bin/sh\nexit 0\n' >"$tmp/repo/bin/$tool"
done
printf '#!/bin/sh\nexit 0\n' >"$tmp/repo/tests/run.sh"
cat >"$tmp/repo/bin/build-adapters.sh" <<'EOF'
#!/bin/sh
if git config --global --includes --get-all llmctx.claudeAccount >/dev/null; then
  echo 'registered account leaked into local-check smoke build' >&2
  exit 1
fi
printf '%s\n' "$HOME" >>"$CHECKS_FIXTURE/smoke-homes"
EOF
chmod +x "$tmp/bin/"* "$tmp/repo/bin/"* "$tmp/repo/tests/run.sh"
PATH="$tmp/bin:$PATH" GIT_CONFIG_GLOBAL="$tmp/global" \
  bash "$SRC/bin/git-hooks/pre-commit-local.agent-harness"
[[ "$(wc -l <"$tmp/smoke-homes" | tr -d ' ')" == 2 ]]
while IFS= read -r smoke_home; do [[ ! -d "$smoke_home" ]]; done <"$tmp/smoke-homes"
[[ ! -e "$tmp/registered-account" ]]
echo "local-check smoke-build account isolation: passed"
