#!/usr/bin/env bash
# Verify that what a repository DECLARES it needs actually resolves on this
# machine. Read-only, no network, no credentials.
#
# Why resolution and not credentials: a repo names an AWS profile, the profile
# is missing from ~/.aws/config here, and the first symptom is an opaque error
# from a command run twenty minutes later. Naming the gap costs a second.
# Whether the profile still has valid credentials only using it can tell you,
# and finding that out is a deploy, not a check.
#
# It never sources .envrc. Sourcing would run arbitrary code from the repo
# during a check, which is the one thing a check must not do.
#
#   llmctx env check [repo]      findings, non-zero if any require attention
#   llmctx env explain [repo]    the declaration, its target, and what is manual
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGETS_DIR="$SRC/targets"
# shellcheck source=lib/policy.sh
source "$SCRIPT_DIR/lib/policy.sh"

mode="${1:-check}"
# With no argument, the REPOSITORY the cwd is in, as explain-policy.sh and
# repo-diff.sh resolve it -- not the cwd itself. The declaration lives at the
# root, and from a package subdirectory this used to print "no .llmctx.json in
# <subdir> -- nothing declared, nothing to check" and exit 0, which reads as a
# pass to anything that checks the exit code (#58). Outside any repository the
# cwd is still the answer: `env check` on a plain directory is meaningful. An
# explicit argument stays literal, because other scripts may rely on it.
if [[ -n "${2:-}" ]]; then
  root="$2"
  [[ -d "$root" ]] || {
    echo "env: not a directory: $root" >&2
    exit 2
  }
  root="$(cd "$root" && pwd)"
else
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

failures=0
add() { # status key detail remediation
  printf '%-8s %-24s %s\n' "$1" "$2" "$3"
  [[ -n "${4:-}" ]] && printf '%*s fix: %s\n' 8 "" "$4"
  case "$1" in MISSING | CONFLICT) failures=$((failures + 1)) ;; esac
  return 0
}

policy_file="$root/.llmctx.json"
[[ -f "$policy_file" ]] || {
  echo "env: no .llmctx.json in $root — nothing declared, nothing to check"
  exit 0
}
command -v jq >/dev/null 2>&1 || {
  echo "env: jq is not installed" >&2
  exit 2
}
llmctx_policy_validate "$root" || {
  echo "env: $LLMCTX_POLICY_ERROR" >&2
  exit 2
}

declared() { jq -r "$1 // empty" "$policy_file"; }
list() { jq -r "$1 // [] | .[]" "$policy_file"; }

target="$(declared '.environment.target')"
[[ -n "$target" ]] || {
  echo "env: $root declares no environment — nothing to check"
  exit 0
}

target_file="$TARGETS_DIR/$target.conf"
[[ -f "$target_file" ]] || {
  add MISSING target "no such target: $target" \
    "add $TARGETS_DIR/$target.conf, or use one of: $(find "$TARGETS_DIR" -name '*.conf' -exec basename {} .conf \; | sort | tr '\n' ' ')"
  exit 1
}

# Read the target file without sourcing it, for the same reason .envrc is not
# sourced: a conf file is data.
field() { sed -n "s/^$1=//p" "$target_file" | head -1; }
split() { tr ',' '\n' <<<"${1:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d'; }

description="$(field description)"

if [[ "$mode" == "explain" ]]; then
  echo "Repository: $root"
  echo "Target:     $target — $description"
  cloud="$(jq -r '.environment.cloud // {} | to_entries[] | "  \(.key) = \(.value)"' "$policy_file")"
  [[ -n "$cloud" ]] && {
    echo "Cloud identifiers (names, not credentials):"
    echo "$cloud"
  }
  for f in requires_cli optional_cli skills; do
    v="$(field "$f")"
    [[ -n "$v" ]] && printf '%-8s    %s\n' "${f%%_*}" "$(split "$v" | tr '\n' ' ')"
  done
  optional="$(field optional_secrets)"
  [[ -n "$optional" ]] && printf '%-8s    %s (this target may need; declare the ones you use)\n' "optional" "$(split "$optional" | tr '\n' ' ')"
  for key in secrets tools mcp; do
    values="$(list ".environment.$key" | tr '\n' ' ')"
    [[ -n "${values// /}" ]] && printf '%-8s    %s\n' "$key" "$values"
  done
  echo
  echo "Still manual, and deliberately:"
  [[ -n "$(field onboard_hint)" ]] && echo "  onboard:  $(field onboard_hint)"
  [[ -n "$(field offboard_hint)" ]] && echo "  offboard: $(field offboard_hint)"
  echo
  echo "Values behind these names live in a vault, and the binding between them"
  echo "lives in workstation. Everything above is a name the validator has"
  echo "checked carries no scheme, host or credential shape."
  exit 0
fi

add OK target "$target — $description" ""

# Required environment variable NAMES must appear in the declaration. This
# checks the declaration is complete, not that a value is set: a value set in
# this shell says nothing about a fresh clone.
declared_env="$(jq -r '.environment.cloud // {} | keys[]' "$policy_file" | tr '\n' ' ')"
while IFS= read -r want; do
  case "$want" in
    AWS_PROFILE) key=awsProfile ;;
    AWS_REGION) key=awsRegion ;;
    CLOUDFLARE_ACCOUNT_ID) key=cloudflareAccount ;;
    *) key="$want" ;;
  esac
  if [[ " $declared_env " == *" $key "* ]]; then
    add OK "env:$want" "declared as cloud.$key" ""
  else
    add MISSING "env:$want" "$target requires it; not declared" \
      "add \"$key\" to .environment.cloud in .llmctx.json"
  fi
done < <(split "$(field requires_env)")

# AWS profile resolution. The CI exemption is measured, not theoretical: a
# runner authenticates with OIDC and has no ~/.aws/config at all, so a declared
# profile cannot resolve there and is not meant to. Only the missing-FILE case
# is exempt — where a config exists, the profile is still checked.
aws_profile="$(declared '.environment.cloud.awsProfile')"
if [[ -n "$aws_profile" ]]; then
  if [[ ! -f "$HOME/.aws/config" ]]; then
    if [[ -n "${CI:-}" ]]; then
      add OK "aws:$aws_profile" "CI — no ~/.aws/config; resolves at deploy time, not here" ""
    else
      add MISSING "aws:$aws_profile" "declared but ~/.aws/config does not exist" \
        "create it, or drop awsProfile from the declaration"
    fi
  # -F and -x: the profile name is data, not a pattern. As a regex, an
  # awsProfile of ".*" reported OK against a config holding only unrelated
  # profiles.
  elif grep -qxF -e "[$aws_profile]" -e "[profile $aws_profile]" "$HOME/.aws/config"; then
    add OK "aws:$aws_profile" "configured in ~/.aws/config" ""
  else
    add MISSING "aws:$aws_profile" "declared but not present in ~/.aws/config" \
      "add the profile, or correct the name in .llmctx.json"
  fi
fi

# Cloudflare account id must agree with wrangler's, where a wrangler config
# exists. Two sources of truth for one account is how a deploy lands in the
# wrong one.
cf_account="$(declared '.environment.cloud.cloudflareAccount')"
if [[ -n "$cf_account" ]]; then
  wrangler_file=""
  for candidate in wrangler.jsonc wrangler.json wrangler.toml; do
    [[ -f "$root/$candidate" ]] && wrangler_file="$root/$candidate" && break
  done
  # Extract wrangler's account id and compare it exactly. The first version
  # was `grep -q "$cf_account"`: unanchored, not fixed-string, and with the
  # declared value reaching grep as a pattern. Measured consequences —
  # cloudflareAccount "-r" made grep read stdin and the check hung; "." matched
  # any non-empty file; and an id mentioned in a migration comment reported
  # agreement with the account the project had moved away from, which is
  # precisely the confusion this check exists to catch.
  found=""
  if [[ -n "$wrangler_file" ]]; then
    case "$wrangler_file" in
      *.toml) found="$(sed -n 's/^[[:space:]]*account_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$wrangler_file" | head -1)" ;;
      *) found="$(sed -n 's/.*"account_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$wrangler_file" | head -1)" ;;
    esac
  fi
  if [[ -z "$wrangler_file" ]]; then
    add OK "cloudflare:account" "declared; no wrangler config to disagree with" ""
  elif [[ -z "$found" ]]; then
    add OK "cloudflare:account" "declared; $(basename "$wrangler_file") sets no account_id" ""
  elif [[ "$found" == "$cf_account" ]]; then
    add OK "cloudflare:account" "agrees with $(basename "$wrangler_file")" ""
  else
    add CONFLICT "cloudflare:account" "declared id is absent from $(basename "$wrangler_file")" \
      "make them agree; a deploy uses wrangler's, not the declaration's"
  fi
fi

while IFS= read -r cli; do
  if command -v "$cli" >/dev/null 2>&1; then
    add OK "cli:$cli" "on PATH" ""
  else
    add MISSING "cli:$cli" "$target requires it" "install $cli"
  fi
done < <(split "$(field requires_cli)")

while IFS= read -r file; do
  if [[ -e "$root/$file" ]]; then
    add OK "file:$file" "present" ""
  else
    add MISSING "file:$file" "expected for target $target" \
      "add it, or reconsider whether $target is the right target"
  fi
done < <(split "$(field check_files)")

# Secrets come from the PROJECT's declaration, not the target's. A target lists
# what its kind of destination may need; only the project knows which of those
# it actually uses, and checking the target's list produces a false finding for
# every Pages site that deploys on push and holds no token.
#
# Checked by NAME only, and only in the gitignored local file. The value is
# never read, printed, or compared.
# The comment above and the fix text both say "the gitignored local file", so
# check that it is one. A committed .envrc.local would otherwise pass this
# section while being exactly the thing the section exists to prevent.
if [[ -f "$root/.envrc.local" ]] && git -C "$root" ls-files --error-unmatch .envrc.local >/dev/null 2>&1; then
  add CONFLICT "secret:storage" ".envrc.local is tracked by git" \
    "git rm --cached .envrc.local and add it to .gitignore; then rotate anything it held"
fi

while IFS= read -r secret; do
  if [[ -f "$root/.envrc.local" ]] && grep -qE "^[[:space:]]*(export[[:space:]]+)?$(printf '%s' "$secret" | sed 's/[^A-Z0-9_]//g')=" "$root/.envrc.local"; then
    add OK "secret:$secret" "bound in .envrc.local" ""
  elif [[ -n "${CI:-}" ]]; then
    add OK "secret:$secret" "CI — supplied by the runner, not bound here" ""
  else
    add MISSING "secret:$secret" "$target needs it; no binding found" \
      "bind it in .envrc.local from the vault; never commit the value"
  fi
done < <(list '.environment.secrets')

echo
if ((failures > 0)); then
  echo "Result: $failures finding(s) require attention"
  exit 1
fi
echo "Result: environment resolves"
