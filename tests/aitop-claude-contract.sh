#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
SCRIPT="$ROOT/aitop-claude"

PASS_COUNT=0
TOTAL_COUNT=0

scenario_list=(
  missing-creds
  invalid-creds
  expired-token
  expired-token-refresh
  request-contract
  success-normal
  success-high-usage
  auth-rejected
  auth-rejected-refresh
  rate-limited
  network-error
  empty-response
)

CRED_MISSING_MSG="Claude Code credentials not found in Keychain. Log in with Claude Code first."
CRED_INVALID_MSG="Claude Code credentials are invalid."
CRED_EXPIRED_MSG="Claude Code OAuth token has expired. Re-authenticate in Claude Code."
AUTH_REJECTED_MSG="Claude OAuth token was rejected. Re-authenticate in Claude Code."
NETWORK_ERR_MSG="Claude usage fetch failed. Check network connectivity and try again."
INVALID_USAGE_MSG="Claude usage details were not present in the response."

make_temp_dir() {
  local base
  base="$(mktemp -d)"
  mkdir -p "$base/mockbin"
  printf '%s' "$base"
}

write_creds() {
  local creds_file="$1"
  local expires_ms="$2"
  cat > "$creds_file" <<EOF
{"claudeAiOauth":{"accessToken":"test-claude-token","refreshToken":"test-refresh-token","expiresAt":${expires_ms},"subscriptionType":"max","rateLimitTier":"default_claude_max_5x","scopes":["user:inference"]}}
EOF
}

setup_mock_security() {
  local temp_dir="$1"
  cat > "$temp_dir/mockbin/security" <<'EOF'
#!/usr/bin/env bash
case "${MOCK_SECURITY_BEHAVIOR:-success}" in
  missing)
    printf 'security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.\n' >&2
    exit 44
    ;;
  invalid)
    printf 'not-valid-json'
    ;;
  success)
    cat "${MOCK_CREDS_FILE:?}"
    ;;
esac
EOF
  chmod +x "$temp_dir/mockbin/security"
}

setup_mock_curl() {
  local temp_dir="$1"
  cat > "$temp_dir/mockbin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

body_file=""
write_out=""
url=""
auth_header=""
accept_header=""
beta_header=""
user_agent_header=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      body_file="$2"
      shift 2
      ;;
    -w)
      write_out="$2"
      shift 2
      ;;
    -H)
      case "$2" in
        Authorization:*)      auth_header="$2" ;;
        Accept:*)             accept_header="$2" ;;
        anthropic-beta:*)     beta_header="$2" ;;
        User-Agent:*)         user_agent_header="$2" ;;
      esac
      shift 2
      ;;
    --max-time|-s|-sS)
      shift 2>/dev/null || shift
      ;;
    http*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [[ "${MOCK_CURL_BEHAVIOR:-}" == "network-error" ]]; then
  exit 28
fi

{
  printf 'URL=%s\n' "$url"
  printf 'AUTH_PRESENT=%s\n' "$( [[ -n "$auth_header" ]] && printf yes || printf no )"
  printf 'ACCEPT=%s\n' "$accept_header"
  printf 'BETA=%s\n' "$beta_header"
  printf 'USER_AGENT=%s\n' "$user_agent_header"
} > "${MOCK_CURL_CAPTURE:?}"

case "${MOCK_CURL_BEHAVIOR:-success-normal}" in
  success-normal|success-high-usage)
    cat "${MOCK_RESPONSE_FILE:?}" > "$body_file"
    printf '200'
    ;;
  auth-rejected-then-success)
    state_file="${MOCK_CURL_STATE_FILE:?}"
    if [[ ! -f "$state_file" ]]; then
      : > "$state_file"
      printf '{"error":"unauthorized"}' > "$body_file"
      printf '401'
    else
      cat "${MOCK_RESPONSE_FILE:?}" > "$body_file"
      printf '200'
    fi
    ;;
  auth-rejected)
    printf '{"error":"unauthorized"}' > "$body_file"
    printf '401'
    ;;
  rate-limited)
    printf '{"error":"rate_limited"}' > "$body_file"
    printf '429'
    ;;
  empty-response)
    printf '{}' > "$body_file"
    printf '200'
    ;;
  *)
    printf '{}' > "$body_file"
    printf '200'
    ;;
esac
EOF
  chmod +x "$temp_dir/mockbin/curl"
}

setup_mock_claude() {
  local temp_dir="$1"
  cat > "$temp_dir/mockbin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${MOCK_CLAUDE_BEHAVIOR:-}" == "refresh-success" ]]; then
  future_ms=$(( $(date +%s) * 1000 + 3600000 ))
  cat > "${MOCK_CREDS_FILE:?}" <<JSON
{"claudeAiOauth":{"accessToken":"test-claude-token","refreshToken":"test-refresh-token","expiresAt":${future_ms},"subscriptionType":"max","rateLimitTier":"default_claude_max_5x","scopes":["user:inference"]}}
JSON
fi

printf 'ok\n'
EOF
  chmod +x "$temp_dir/mockbin/claude"
}

write_response_normal() {
  local response_file="$1"
  local five_h_reset="$2"
  local seven_d_reset="$3"
  cat > "$response_file" <<EOF
{"five_hour":{"utilization":15.0,"resets_at":"${five_h_reset}"},"seven_day":{"utilization":2.0,"resets_at":"${seven_d_reset}"},"seven_day_sonnet":{"utilization":0.0,"resets_at":null},"seven_day_opus":null,"extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null}}
EOF
}

write_response_high() {
  local response_file="$1"
  local five_h_reset="$2"
  local seven_d_reset="$3"
  cat > "$response_file" <<EOF
{"five_hour":{"utilization":92.0,"resets_at":"${five_h_reset}"},"seven_day":{"utilization":60.0,"resets_at":"${seven_d_reset}"},"seven_day_sonnet":{"utilization":45.0,"resets_at":"${seven_d_reset}"},"seven_day_opus":null,"extra_usage":{"is_enabled":false}}
EOF
}

run_script() {
  local temp_dir="$1"
  local curl_behavior="$2"
  local capture_file="$temp_dir/curl-capture.txt"
  local state_file="$temp_dir/curl-state.txt"
  local out_file="$temp_dir/out.txt"
  local err_file="$temp_dir/err.txt"

  setup_mock_security "$temp_dir"
  setup_mock_curl "$temp_dir"
  setup_mock_claude "$temp_dir"

  PATH="$temp_dir/mockbin:$PATH" \
    MOCK_SECURITY_BEHAVIOR="success" \
    MOCK_CREDS_FILE="$temp_dir/creds.json" \
    MOCK_CLAUDE_BEHAVIOR="${MOCK_CLAUDE_BEHAVIOR:-}" \
    MOCK_CURL_BEHAVIOR="$curl_behavior" \
    MOCK_CURL_CAPTURE="$capture_file" \
    MOCK_CURL_STATE_FILE="$state_file" \
    MOCK_RESPONSE_FILE="$temp_dir/response.json" \
    CLAUDE_USAGE_CACHE=0 \
    "$SCRIPT" >"$out_file" 2>"$err_file" || return $?
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -F "$expected" "$file" >/dev/null
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  ! grep -F "$needle" "$file" >/dev/null
}

record_pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
}

run_scenario() {
  local scenario="$1"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  local temp_dir now_ms future_ms now_epoch
  temp_dir="$(make_temp_dir)"
  now_ms=$(( $(date +%s) * 1000 ))
  now_epoch=$(date +%s)
  future_ms=$((now_ms + 3600000))

  local five_h_reset seven_d_reset
  five_h_reset="$(TZ=UTC date -r "$((now_epoch + 4000))" '+%Y-%m-%dT%H:%M:%S+00:00')"
  seven_d_reset="$(TZ=UTC date -r "$((now_epoch + 302400))" '+%Y-%m-%dT%H:%M:%S+00:00')"

  case "$scenario" in
    missing-creds)
      setup_mock_security "$temp_dir"
      if PATH="$temp_dir/mockbin:$PATH" MOCK_SECURITY_BEHAVIOR="missing" CLAUDE_USAGE_CACHE=0 "$SCRIPT" >"$temp_dir/out.txt" 2>"$temp_dir/err.txt"; then
        return 1
      fi
      assert_contains "$temp_dir/err.txt" "$CRED_MISSING_MSG"
      ;;

    invalid-creds)
      setup_mock_security "$temp_dir"
      if PATH="$temp_dir/mockbin:$PATH" MOCK_SECURITY_BEHAVIOR="invalid" CLAUDE_USAGE_CACHE=0 "$SCRIPT" >"$temp_dir/out.txt" 2>"$temp_dir/err.txt"; then
        return 1
      fi
      assert_contains "$temp_dir/err.txt" "$CRED_INVALID_MSG"
      ;;

    expired-token)
      write_creds "$temp_dir/creds.json" $((now_ms - 1000))
      setup_mock_security "$temp_dir"
      setup_mock_claude "$temp_dir"
      if PATH="$temp_dir/mockbin:$PATH" MOCK_SECURITY_BEHAVIOR="success" MOCK_CREDS_FILE="$temp_dir/creds.json" CLAUDE_USAGE_CACHE=0 "$SCRIPT" >"$temp_dir/out.txt" 2>"$temp_dir/err.txt"; then
        return 1
      fi
      assert_contains "$temp_dir/err.txt" "$CRED_EXPIRED_MSG"
      ;;

    expired-token-refresh)
      write_creds "$temp_dir/creds.json" $((now_ms - 1000))
      write_response_normal "$temp_dir/response.json" "$five_h_reset" "$seven_d_reset"
      MOCK_CLAUDE_BEHAVIOR="refresh-success" run_script "$temp_dir" "success-normal"
      assert_contains "$temp_dir/out.txt" '15% used'
      assert_contains "$temp_dir/out.txt" '5-hour'
      ;;

    request-contract)
      write_creds "$temp_dir/creds.json" "$future_ms"
      write_response_normal "$temp_dir/response.json" "$five_h_reset" "$seven_d_reset"
      run_script "$temp_dir" "success-normal"
      assert_contains "$temp_dir/curl-capture.txt" 'URL=https://api.anthropic.com/api/oauth/usage'
      assert_contains "$temp_dir/curl-capture.txt" 'AUTH_PRESENT=yes'
      assert_contains "$temp_dir/curl-capture.txt" 'BETA=anthropic-beta: oauth-2025-04-20'
      assert_contains "$temp_dir/curl-capture.txt" 'USER_AGENT=User-Agent: aitop-claude'
      cat "$temp_dir/curl-capture.txt"
      ;;

    success-normal)
      write_creds "$temp_dir/creds.json" "$future_ms"
      write_response_normal "$temp_dir/response.json" "$five_h_reset" "$seven_d_reset"
      run_script "$temp_dir" "success-normal"
      assert_contains "$temp_dir/out.txt" '15% used'
      assert_contains "$temp_dir/out.txt" '5-hour'
      assert_contains "$temp_dir/out.txt" ' 2% used'
      assert_contains "$temp_dir/out.txt" '7-day'
      assert_contains "$temp_dir/out.txt" 'resets in'
      assert_contains "$temp_dir/out.txt" '            5h '
      assert_contains "$temp_dir/out.txt" '50% elapsed'
      cat "$temp_dir/out.txt"
      ;;

    success-high-usage)
      write_creds "$temp_dir/creds.json" "$future_ms"
      write_response_high "$temp_dir/response.json" "$five_h_reset" "$seven_d_reset"
      run_script "$temp_dir" "success-high-usage"
      assert_contains "$temp_dir/out.txt" '92% used'
      assert_contains "$temp_dir/out.txt" 'ahead'
      assert_contains "$temp_dir/out.txt" '60% used'
      assert_contains "$temp_dir/out.txt" '45% used'
      assert_contains "$temp_dir/out.txt" '7d sonnet'
      cat "$temp_dir/out.txt"
      ;;

    auth-rejected)
      write_creds "$temp_dir/creds.json" "$future_ms"
      write_response_normal "$temp_dir/response.json" "$five_h_reset" "$seven_d_reset"
      if run_script "$temp_dir" "auth-rejected"; then
        return 1
      fi
      assert_contains "$temp_dir/err.txt" "$AUTH_REJECTED_MSG"
      ;;

    auth-rejected-refresh)
      write_creds "$temp_dir/creds.json" "$future_ms"
      write_response_normal "$temp_dir/response.json" "$five_h_reset" "$seven_d_reset"
      MOCK_CLAUDE_BEHAVIOR="refresh-success" run_script "$temp_dir" "auth-rejected-then-success"
      assert_contains "$temp_dir/out.txt" '15% used'
      assert_contains "$temp_dir/out.txt" '7-day'
      ;;

    rate-limited)
      write_creds "$temp_dir/creds.json" "$future_ms"
      write_response_normal "$temp_dir/response.json" "$five_h_reset" "$seven_d_reset"
      if run_script "$temp_dir" "rate-limited"; then
        return 1
      fi
      assert_contains "$temp_dir/err.txt" 'rate limited'
      ;;

    network-error)
      write_creds "$temp_dir/creds.json" "$future_ms"
      setup_mock_security "$temp_dir"
      setup_mock_curl "$temp_dir"
      if PATH="$temp_dir/mockbin:$PATH" \
        MOCK_SECURITY_BEHAVIOR="success" \
        MOCK_CREDS_FILE="$temp_dir/creds.json" \
        MOCK_CURL_BEHAVIOR="network-error" \
        MOCK_CURL_CAPTURE="$temp_dir/curl-capture.txt" \
        MOCK_RESPONSE_FILE="$temp_dir/response.json" \
        CLAUDE_USAGE_CACHE=0 \
        "$SCRIPT" >"$temp_dir/out.txt" 2>"$temp_dir/err.txt"; then
        return 1
      fi
      assert_contains "$temp_dir/err.txt" "$NETWORK_ERR_MSG"
      ;;

    empty-response)
      write_creds "$temp_dir/creds.json" "$future_ms"
      write_response_normal "$temp_dir/response.json" "$five_h_reset" "$seven_d_reset"
      run_script "$temp_dir" "empty-response"
      grep -Fx "$INVALID_USAGE_MSG" "$temp_dir/out.txt" >/dev/null
      ;;

    *)
      printf 'unknown scenario: %s\n' "$scenario" >&2
      return 1
      ;;
  esac

  assert_not_contains "$temp_dir/out.txt" 'test-claude-token'
  assert_not_contains "$temp_dir/out.txt" 'test-refresh-token'
  assert_not_contains "$temp_dir/err.txt" 'test-claude-token'
  assert_not_contains "$temp_dir/err.txt" 'test-refresh-token'

  record_pass
  printf 'PASS %s\n' "$scenario"
}

main() {
  local requested=()
  if [[ $# -gt 0 ]]; then
    requested=("$@")
  else
    requested=("${scenario_list[@]}")
  fi

  local scenario
  for scenario in "${requested[@]}"; do
    run_scenario "$scenario"
  done

  printf 'PASS: %d/%d aitop-claude scenarios\n' "$PASS_COUNT" "$TOTAL_COUNT"
}

main "$@"
