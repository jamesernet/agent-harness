#!/usr/bin/env bash
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/harness-runner-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/suite" "$tmp/caller" "$tmp/xdg" "$tmp/template"
cp "$SRC/tests/run.sh" "$tmp/suite/run.sh"
printf '[test]\nexternal = unsafe\n[init]\ntemplateDir = %s\n' "$tmp/template" >"$tmp/global"
cp "$tmp/global" "$tmp/global-before"
touch "$tmp/template/inherited-template"
export RUN_ENVIRONMENT_LOG="$tmp/probe-home" RUN_ENVIRONMENT_REPO="$tmp/probe-repo"
cat >"$tmp/suite/probe-test.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if git config --get test.external >/dev/null; then
  echo 'test runner inherited caller Git configuration' >&2
  exit 1
fi
printf '%s\n' "$HOME" >"$RUN_ENVIRONMENT_LOG"
git init -q "$RUN_ENVIRONMENT_REPO"
[[ ! -e "$RUN_ENVIRONMENT_REPO/.git/inherited-template" ]]
git config --global test.local fixture
[[ "$(git config --global test.local)" == fixture ]]
EOF
HOME="$tmp/caller" XDG_CONFIG_HOME="$tmp/xdg" GIT_CONFIG_GLOBAL="$tmp/global" \
  bash "$tmp/suite/run.sh"
cmp -s "$tmp/global" "$tmp/global-before"
[[ "$(cat "$RUN_ENVIRONMENT_LOG")" != "$tmp/caller" ]]
[[ ! -d "$(cat "$RUN_ENVIRONMENT_LOG")" ]]
echo "test runner environment isolation: passed"
