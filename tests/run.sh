#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Git exports repository-local variables to hooks. Clear them before tests
# create temporary repositories, or their Git commands can mutate the caller.
while IFS= read -r variable; do
  unset "$variable"
done < <(git rev-parse --local-env-vars)

# A configured workstation can install templates or resolve registered provider
# homes even when a test changes HOME. Keep the suite independent of caller Git
# and XDG configuration; individual tests still create their own fixtures.
unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT
unset XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME
export GIT_CONFIG_NOSYSTEM=1
test_home="$(mktemp -d "${TMPDIR:-/tmp}/harness-suite-home.XXXXXX")"
trap 'rm -rf "$test_home"' EXIT

for test_file in "$SCRIPT_DIR"/*-test.sh; do
  HOME="$test_home" bash "$test_file"
done
