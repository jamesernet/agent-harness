# shellcheck shell=bash
# shellcheck disable=SC2034 # resolved values are consumed by scripts that source this library

# Shared agent-harness repository policy resolution. Source this file; it does not
# execute anything on its own. Compatible with the Bash 3.2 shipped by macOS.

LLMCTX_POLICY_SCHEMA_VERSION=1
LLMCTX_POLICY_ERROR=""

llmctx_policy_error() {
  LLMCTX_POLICY_ERROR="$1"
  return 1
}

llmctx_policy_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

llmctx_policy_file() {
  printf '%s/.llmctx.json\n' "$1"
}

llmctx_policy_validate() {
  local root="$1" file schema profile branch_policy invalid_branch invalid_environment
  file="$(llmctx_policy_file "$root")"
  LLMCTX_POLICY_ERROR=""
  [[ -f "$file" ]] || return 0

  command -v jq >/dev/null 2>&1 || {
    llmctx_policy_error "cannot read $file: jq is not installed"
    return 1
  }
  jq empty "$file" >/dev/null 2>&1 || {
    llmctx_policy_error "invalid JSON: $file"
    return 1
  }

  schema="$(jq -r '.schemaVersion // empty' "$file")"
  [[ "$schema" == "$LLMCTX_POLICY_SCHEMA_VERSION" ]] || {
    llmctx_policy_error "unsupported schemaVersion in $file: ${schema:-missing}"
    return 1
  }

  profile="$(jq -r '.profile // empty' "$file")"
  case "$profile" in
    "" | personal | client) ;;
    *)
      llmctx_policy_error "invalid profile in $file: $profile"
      return 1
      ;;
  esac

  branch_policy="$(jq -r '.branchPolicy // empty' "$file")"
  case "$branch_policy" in
    "" | off | remind | ask | deny) ;;
    *)
      llmctx_policy_error "invalid branchPolicy in $file: $branch_policy"
      return 1
      ;;
  esac

  # environment: what a project needs to run and deploy, declared by NAME.
  #
  # Every string in this block is constrained, not just `secrets`. The first
  # version checked `secrets` alone, which let a vault path sit in
  # `cloud.awsProfile`, an SSO start URL in `cloud`, and a key id in `tools` —
  # all accepted, then printed back by `llmctx env explain` under a line
  # reading "Nothing here is a credential". The whole reason an environment
  # block is safe to commit to a repository a client can read is that this
  # function keeps credentials out of it, so the constraint has to cover every
  # field a caller might reach for, and `cloud` is where `vaultPath` looks
  # natural.
  #
  # Two layers. Shape rejects anything that is not a plain identifier, which
  # kills references and URLs outright. The credential denylist then catches
  # what is shaped like a name but is not one: an access key id and a live
  # secret key both match [A-Za-z0-9._-]+ perfectly well.
  #
  # Type checks run BEFORE pattern checks throughout. jq's test() raises on a
  # non-string, the error goes to stderr, the capture comes back empty and the
  # emptiness test then reads as success — so an unguarded test() does not fail
  # closed, it fails open, and {"op":"vault://x"} was accepted as a secret name.
  invalid_environment="$(jq -r '
    def cred: test("://|@|-----BEGIN|\\b(AKIA|ASIA)[0-9A-Z]{16}\\b|^(sk|rk|pk)-[a-zA-Z]|^ghp_|^gho_|^github_pat_|^xox[baprs]-|^AIza[0-9A-Za-z_-]{20}");
    def allstrings: [.. | strings];
    if (has("environment") | not) then ""
    elif (.environment | type) != "object" then "environment must be an object"
    elif (.environment | has("target") | not) or (.environment.target == "") then "environment.target is required"
    elif (.environment.target | type) != "string" then "environment.target must be a string"
    elif (.environment.target | test("^[a-z0-9][a-z0-9-]*$") | not)
      then "environment.target must be a lowercase slug"

    elif (.environment | has("cloud")) and ((.environment.cloud | type) != "object")
      then "environment.cloud must be an object"
    elif [(.environment.cloud // {}) | to_entries[] | select((.value | type) != "string")] | length > 0
      then "environment.cloud values must be strings"
    elif [(.environment.cloud // {}) | to_entries[] | select(.value == "" or (.value | test("^[A-Za-z0-9][A-Za-z0-9._-]*$") | not))] | length > 0
      then "environment.cloud values must be plain identifiers: a profile name, region or account id, never a reference or a URL"

    elif [(.environment.secrets // []), (.environment.tools // []), (.environment.mcp // [])
          | select(type != "array")] | length > 0
      then "environment.secrets, .tools and .mcp must be arrays"
    elif [(.environment.secrets // [])[], (.environment.tools // [])[], (.environment.mcp // [])[]
          | select(type != "string")] | length > 0
      then "environment.secrets, .tools and .mcp must contain strings"
    elif [(.environment.secrets // [])[] | select(test("://"))] | length > 0
      then "environment.secrets must not contain references; the binding between a name and its value lives in workstation"
    elif [(.environment.secrets // [])[] | select(test("^[A-Z][A-Z0-9_]*$") | not)] | length > 0
      then "environment.secrets must be environment variable NAMES, not values"
    elif [(.environment.tools // [])[], (.environment.mcp // [])[] | select(test("^[a-z0-9][a-z0-9._-]*$") | not)] | length > 0
      then "environment.tools and .mcp must be plain names"
    elif (.environment | has("skills")) and ((.environment.skills | type) != "string" or (.environment.skills | test("^[a-z0-9][a-z0-9-]*$") | not))
      then "environment.skills must be a bundle name"

    elif [.environment | allstrings[] | select(cred)] | length > 0
      then "environment must carry no credential: a key, a token or anything with a scheme or host in it belongs in a vault"
    else "" end
  ' "$file" 2>/dev/null)"
  [[ -z "$invalid_environment" ]] || {
    llmctx_policy_error "$invalid_environment in $file"
    return 1
  }

  invalid_branch="$(jq -r '
    if has("protectedBranches") and
       ((.protectedBranches | type) != "array" or
        (.protectedBranches | length) == 0 or
        any(.protectedBranches[]; type != "string" or length == 0))
    then "invalid" else "" end
  ' "$file")"
  [[ -z "$invalid_branch" ]] || {
    llmctx_policy_error "protectedBranches must be a non-empty string array in $file"
    return 1
  }
}

llmctx_policy_resolve() {
  local root="$1" file value profile_default
  llmctx_policy_validate "$root" || return 1
  file="$(llmctx_policy_file "$root")"

  if value="$(git -C "$root" config --local --get llmctx.profile 2>/dev/null)"; then
    LLMCTX_PROFILE="$value"
    LLMCTX_PROFILE_SOURCE="git-local"
  elif [[ -f "$file" ]] && value="$(jq -r '.profile // empty' "$file")" && [[ -n "$value" ]]; then
    LLMCTX_PROFILE="$value"
    LLMCTX_PROFILE_SOURCE="repo-policy"
  else
    LLMCTX_PROFILE="personal"
    LLMCTX_PROFILE_SOURCE="built-in"
  fi
  case "$LLMCTX_PROFILE" in
    personal | client) ;;
    *) llmctx_policy_error "invalid resolved profile: $LLMCTX_PROFILE" || return 1 ;;
  esac

  [[ "$LLMCTX_PROFILE" == "client" ]] && profile_default="deny" || profile_default="remind"
  if value="$(git -C "$root" config --local --get llmctx.branchPolicy 2>/dev/null)"; then
    LLMCTX_BRANCH_POLICY="$value"
    LLMCTX_BRANCH_POLICY_SOURCE="git-local"
  elif [[ -f "$file" ]] && value="$(jq -r '.branchPolicy // empty' "$file")" && [[ -n "$value" ]]; then
    LLMCTX_BRANCH_POLICY="$value"
    LLMCTX_BRANCH_POLICY_SOURCE="repo-policy"
  elif value="$(git config --global --get llmctx.branchPolicy 2>/dev/null)"; then
    LLMCTX_BRANCH_POLICY="$value"
    LLMCTX_BRANCH_POLICY_SOURCE="git-global"
  else
    LLMCTX_BRANCH_POLICY="$profile_default"
    LLMCTX_BRANCH_POLICY_SOURCE="built-in:$LLMCTX_PROFILE"
  fi
  case "$LLMCTX_BRANCH_POLICY" in
    off | remind | ask | deny) ;;
    *) llmctx_policy_error "invalid resolved branchPolicy: $LLMCTX_BRANCH_POLICY" || return 1 ;;
  esac

  if value="$(git -C "$root" config --local --get llmctx.protectedBranches 2>/dev/null)"; then
    LLMCTX_PROTECTED_BRANCHES="$value"
    LLMCTX_PROTECTED_BRANCHES_SOURCE="git-local"
  elif [[ -f "$file" ]] && value="$(jq -r '.protectedBranches // [] | join(" ")' "$file")" && [[ -n "$value" ]]; then
    LLMCTX_PROTECTED_BRANCHES="$value"
    LLMCTX_PROTECTED_BRANCHES_SOURCE="repo-policy"
  elif value="$(git config --global --get llmctx.protectedBranches 2>/dev/null)"; then
    LLMCTX_PROTECTED_BRANCHES="$value"
    LLMCTX_PROTECTED_BRANCHES_SOURCE="git-global"
  else
    LLMCTX_PROTECTED_BRANCHES="main master"
    LLMCTX_PROTECTED_BRANCHES_SOURCE="built-in"
  fi
  [[ -n "$LLMCTX_PROTECTED_BRANCHES" ]] ||
    llmctx_policy_error "resolved protectedBranches is empty"
}
