# shellcheck shell=bash
# Read the same explicit policy as env check. No AWS command or credential file
# is opened. An installed hook finds its libraries beside itself.
llmctx_context_session_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$llmctx_context_session_lib/llmctx-context-policy.sh" ]]; then
  # shellcheck source=context-policy.sh
  source "$llmctx_context_session_lib/llmctx-context-policy.sh"
else
  # shellcheck source=context-policy.sh
  source "$llmctx_context_session_lib/context-policy.sh"
fi

llmctx_context_session_message() (
  local root="$1" variable read_profile issues="" active
  # A hook's inherited Git directory must not select another repo's policy.
  while IFS= read -r variable; do unset "$variable"; done < <(git rev-parse --local-env-vars)
  llmctx_context_policy_load "$root"
  [[ "$LLMCTX_CONTEXT_POLICY_STATE" != absent ]] || return 0
  if [[ "$LLMCTX_CONTEXT_POLICY_STATE" == invalid ]]; then
    printf 'The session context policy could not be checked. %s\n' "$LLMCTX_CONTEXT_POLICY_ERROR"
    return 0
  fi
  read_profile="$(jq -r '.awsReadProfile // empty' <<<"$LLMCTX_CONTEXT_POLICY_JSON")"
  active="${AWS_PROFILE:-}"
  if [[ -n "$read_profile" ]]; then
    if [[ "$active" != "$read_profile" ]]; then
      issues="AWS_PROFILE does not match the context's declared read-only ambient profile ($read_profile)."
    fi
    if [[ -n "${AWS_DEFAULT_PROFILE:-}" && "${AWS_DEFAULT_PROFILE}" != "$read_profile" ]]; then
      issues="${issues}${issues:+$'\n'}AWS_DEFAULT_PROFILE selects another profile."
    fi
  elif [[ -n "$active" && "$active" != __workstation_unbound__ ]] || [[ -n "${AWS_DEFAULT_PROFILE:-}" && "${AWS_DEFAULT_PROFILE}" != __workstation_unbound__ ]]; then
    issues="This context declares no ambient AWS profile, but the session selects one."
  fi
  for variable in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_ROLE_SESSION_NAME AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_AUTHORIZATION_TOKEN AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE; do
    if [[ -n "${!variable:-}" ]]; then
      issues="${issues}${issues:+$'\n'}$variable is set and can override profile-based isolation."
    fi
  done
  if [[ -n "${AWS_CONFIG_FILE:-}" && "$AWS_CONFIG_FILE" != "$HOME/.aws/config" ]]; then
    issues="${issues}${issues:+$'\n'}AWS_CONFIG_FILE selects a non-default configuration."
  fi
  if [[ -n "${AWS_SHARED_CREDENTIALS_FILE:-}" && "$AWS_SHARED_CREDENTIALS_FILE" != /dev/null ]]; then
    issues="${issues}${issues:+$'\n'}AWS_SHARED_CREDENTIALS_FILE enables a separate credential source."
  fi
  [[ -n "$issues" ]] || return 0
  printf '%s\n\n%s\n' "$issues" \
    'Clear credential overrides and reload the owner-approved context environment before continuing. This is a startup notice, not an execution boundary; IAM permissions and live credentials were not verified.'
)
