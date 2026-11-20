# shellcheck shell=bash
# shellcheck disable=SC2034 # results are consumed by callers that source this library
# Machine-local binding, also usable from a path-scoped Git include. This
# library reads only an explicit file; it never scans workstation or sources it.

llmctx_context_policy_load() {
  local root="$1" file variable
  LLMCTX_CONTEXT_POLICY_STATE=absent
  LLMCTX_CONTEXT_POLICY_ERROR=""
  LLMCTX_CONTEXT_POLICY_JSON='{}'
  file="$(
    while IFS= read -r variable; do unset "$variable"; done < <(git rev-parse --local-env-vars)
    git -C "$root" config --path --get llmctx.contextProfile 2>/dev/null
  )" || return 0
  LLMCTX_CONTEXT_POLICY_STATE=invalid
  if [[ "$file" != /* || ! -f "$file" ]]; then
    LLMCTX_CONTEXT_POLICY_ERROR="llmctx.contextProfile must name an existing absolute TOML path"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    LLMCTX_CONTEXT_POLICY_ERROR="context policy requires Python 3.11 or newer"
    return 0
  fi
  if ! LLMCTX_CONTEXT_POLICY_JSON="$(
    python3 - "$file" 2>/dev/null <<'PYTHON'
import json
import re
import sys

try:
    import tomllib
except ImportError:
    sys.exit("context policy requires Python 3.11 or newer")


def load(path):
    with open(path, "rb") as stream:
        data = tomllib.load(stream)
    for section in ("context", "cloud", "aws", "ai"):
        if section in data and not isinstance(data[section], dict):
            raise ValueError(f"{section} must be a table")

    def name(section, key):
        value = data.get(section, {}).get(key)
        if value is not None and (
            not isinstance(value, str)
            or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value) is None
        ):
            raise ValueError(f"{section}.{key} must be a plain identifier")
        return value

    def flag(key):
        value = data.get("ai", {}).get(key)
        if value is not None and type(value) is not bool:
            raise ValueError(f"ai.{key} must be a boolean")
        return value

    def profile(canonical, legacy):
        current = name("cloud", canonical)
        old = name("aws", legacy)
        if current is not None and old is not None and current != old:
            raise ValueError("canonical and legacy AWS policy disagree")
        return current if current is not None else old

    read = profile("aws_profile", "default_profile")
    write = profile("aws_write_profile", "write_profile")
    if read is not None and read == write:
        raise ValueError("read and write AWS profiles must differ")
    return {
        "contextId": name("context", "id"),
        "awsReadProfile": read,
        "awsWriteProfile": write,
        "allowCodeEgress": flag("allow_code_egress"),
        "agentsAllowed": flag("agents_allowed"),
    }


try:
    print(json.dumps(load(sys.argv[1])))
except (OSError, ValueError, IndexError):
    # A parser error can quote source text. Never echo private TOML contents.
    sys.exit("context policy is unreadable or invalid; check its TOML and policy field types")
PYTHON
  )"; then
    LLMCTX_CONTEXT_POLICY_ERROR="context policy is unreadable or invalid; Python 3.11+ and valid TOML policy fields are required"
    LLMCTX_CONTEXT_POLICY_JSON='{}'
    return 0
  fi
  LLMCTX_CONTEXT_POLICY_STATE=loaded
}
