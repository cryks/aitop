#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
SCRIPT="$ROOT/aitop-gemini"

PASS_COUNT=0
TOTAL_COUNT=0

scenario_list=(
  missing-settings
  missing-creds
  unsupported-auth
  missing-paid-project
  request-contract
  success-normal
  no-pro-bucket
  expired-token-refresh
  auth-rejected
  network-error
  empty-response
)

SETTINGS_MISSING_MSG="Gemini CLI settings were not found. Log in with Gemini CLI first."
CRED_MISSING_MSG="Gemini CLI OAuth credentials were not found. Log in with Gemini CLI first."
AUTH_UNSUPPORTED_MSG="Gemini auth type is unsupported. Use Gemini CLI personal OAuth login."
PROJECT_MISSING_MSG="Gemini project details were not present in the response."
AUTH_REJECTED_MSG="Gemini OAuth token was rejected. Re-authenticate in Gemini CLI."
NETWORK_ERR_MSG="Gemini usage fetch failed. Check network connectivity and try again."
INVALID_USAGE_MSG="Gemini usage details were not present in the response."

make_temp_home() {
  local base
  base="$(mktemp -d)"
  mkdir -p "$base/.gemini" "$base/mockbin"
  printf '%s' "$base"
}

write_settings() {
  local home_dir="$1"
  local auth_type="$2"
  cat > "$home_dir/.gemini/settings.json" <<EOF
{"security":{"auth":{"selectedType":"${auth_type}"}}}
EOF
}

write_creds() {
  local home_dir="$1"
  local expiry_ms="$2"
  cat > "$home_dir/.gemini/oauth_creds.json" <<EOF
{"access_token":"test-gemini-token","refresh_token":"test-refresh-token","id_token":"test-id-token","expiry_date":${expiry_ms}}
EOF
}

write_load_response() {
  local file="$1"
  cat > "$file" <<'EOF'
{"cloudaicompanionProject":"robotic-terrain-f9xhg","currentTier":{"id":"standard-tier"}}
EOF
}

write_load_response_missing_project() {
  local file="$1"
  cat > "$file" <<'EOF'
{"currentTier":{"id":"standard-tier"}}
EOF
}

write_quota_response_normal() {
  local file="$1"
  cat > "$file" <<'EOF'
{"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.61,"resetTime":"2026-03-13T01:43:49Z"},{"modelId":"gemini-3.1-pro-preview","remainingFraction":0.61,"resetTime":"2026-03-13T01:43:49Z"},{"modelId":"gemini-2.5-flash","remainingFraction":1.0,"resetTime":"2026-03-13T07:41:10Z"}]}
EOF
}

write_quota_response_non_pro() {
  local file="$1"
  cat > "$file" <<'EOF'
{"buckets":[{"modelId":"gemini-2.5-flash","remainingFraction":0.25,"resetTime":"2026-03-13T07:41:10Z"}]}
EOF
}

write_refresh_response() {
  local file="$1"
  cat > "$file" <<'EOF'
{"access_token":"refreshed-gemini-token","refresh_token":"rotated-refresh-token","expires_in":3600,"id_token":"refreshed-id-token"}
EOF
}

setup_mock_curl() {
  local home_dir="$1"
  cat > "$home_dir/mockbin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

body_file=""
write_out=""
url=""
method="POST"
data=""
auth_header=""
content_type=""
accept_header=""

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
        Authorization:*) auth_header="$2" ;;
        Content-Type:*)  content_type="$2" ;;
        Accept:*)        accept_header="$2" ;;
      esac
      shift 2
      ;;
    -X)
      method="$2"
      shift 2
      ;;
    --data)
      data="$2"
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

call_type="other"
case "$url" in
  *v1internal:loadCodeAssist)   call_type="load" ;;
  *v1internal:retrieveUserQuota) call_type="quota" ;;
  *oauth2.googleapis.com/token) call_type="refresh" ;;
esac

{
  printf 'CALL_TYPE=%s\n' "$call_type"
  printf 'URL=%s\n' "$url"
  printf 'METHOD=%s\n' "$method"
  printf 'AUTH_PRESENT=%s\n' "$( [[ -n "$auth_header" ]] && printf yes || printf no )"
  printf 'CONTENT_TYPE=%s\n' "$content_type"
  printf 'ACCEPT=%s\n' "$accept_header"
  printf 'DATA=%s\n' "$data"
} >> "${MOCK_CURL_CAPTURE:?}"

case "$call_type" in
  load)
    case "${MOCK_CURL_BEHAVIOR:-success-normal}" in
      auth-rejected)
        printf '{"error":"unauthorized"}' > "$body_file"
        printf '401'
        ;;
      *)
        cat "${MOCK_LOAD_RESPONSE:?}" > "$body_file"
        printf '200'
        ;;
    esac
    ;;
  quota)
    case "${MOCK_CURL_BEHAVIOR:-success-normal}" in
      empty-response)
        printf '{}' > "$body_file"
        printf '200'
        ;;
      no-pro-bucket)
        cat "${MOCK_QUOTA_RESPONSE:?}" > "$body_file"
        printf '200'
        ;;
      *)
        cat "${MOCK_QUOTA_RESPONSE:?}" > "$body_file"
        printf '200'
        ;;
    esac
    ;;
  refresh)
    cat "${MOCK_REFRESH_RESPONSE:?}" > "$body_file"
    printf '200'
    ;;
  *)
    printf '{}' > "$body_file"
    printf '200'
    ;;
esac
EOF
  chmod +x "$home_dir/mockbin/curl"
}

run_script() {
  local home_dir="$1"
  local behavior="$2"
  local out_file="$home_dir/out.txt"
  local err_file="$home_dir/err.txt"
  local capture_file="$home_dir/curl-capture.txt"

  setup_mock_curl "$home_dir"
  : > "$capture_file"

  PATH="$home_dir/mockbin:$PATH" \
    HOME="$home_dir" \
    MOCK_CURL_BEHAVIOR="$behavior" \
    MOCK_CURL_CAPTURE="$capture_file" \
    MOCK_LOAD_RESPONSE="$home_dir/load-response.json" \
    MOCK_QUOTA_RESPONSE="$home_dir/quota-response.json" \
    MOCK_REFRESH_RESPONSE="$home_dir/refresh-response.json" \
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
  local home_dir now_ms future_ms
  home_dir="$(make_temp_home)"
  now_ms=$(( $(date +%s) * 1000 ))
  future_ms=$((now_ms + 3600000))

  write_load_response "$home_dir/load-response.json"
  write_quota_response_normal "$home_dir/quota-response.json"
  write_refresh_response "$home_dir/refresh-response.json"

  case "$scenario" in
    missing-settings)
      if HOME="$home_dir" "$SCRIPT" >"$home_dir/out.txt" 2>"$home_dir/err.txt"; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "$SETTINGS_MISSING_MSG"
      ;;
    missing-creds)
      write_settings "$home_dir" oauth-personal
      if HOME="$home_dir" "$SCRIPT" >"$home_dir/out.txt" 2>"$home_dir/err.txt"; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "$CRED_MISSING_MSG"
      ;;
    unsupported-auth)
      write_settings "$home_dir" api-key
      write_creds "$home_dir" "$future_ms"
      if HOME="$home_dir" "$SCRIPT" >"$home_dir/out.txt" 2>"$home_dir/err.txt"; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "$AUTH_UNSUPPORTED_MSG"
      ;;
    missing-paid-project)
      write_settings "$home_dir" oauth-personal
      write_creds "$home_dir" "$future_ms"
      write_load_response_missing_project "$home_dir/load-response.json"
      if run_script "$home_dir" success-normal; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "$PROJECT_MISSING_MSG"
      assert_not_contains "$home_dir/curl-capture.txt" 'CALL_TYPE=quota'
      ;;
    request-contract)
      write_settings "$home_dir" oauth-personal
      write_creds "$home_dir" "$future_ms"
      run_script "$home_dir" success-normal
      assert_contains "$home_dir/curl-capture.txt" 'CALL_TYPE=load'
      assert_contains "$home_dir/curl-capture.txt" 'URL=https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist'
      assert_contains "$home_dir/curl-capture.txt" 'AUTH_PRESENT=yes'
      assert_contains "$home_dir/curl-capture.txt" 'CONTENT_TYPE=Content-Type: application/json'
      assert_contains "$home_dir/curl-capture.txt" 'DATA={"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}'
      assert_contains "$home_dir/curl-capture.txt" 'CALL_TYPE=quota'
      assert_contains "$home_dir/curl-capture.txt" 'URL=https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota'
      assert_contains "$home_dir/curl-capture.txt" 'DATA={"project": "robotic-terrain-f9xhg"}'
      cat "$home_dir/curl-capture.txt"
      ;;
    success-normal)
      write_settings "$home_dir" oauth-personal
      write_creds "$home_dir" "$future_ms"
      run_script "$home_dir" success-normal
      assert_contains "$home_dir/out.txt" '* Gemini · paid'
      assert_contains "$home_dir/out.txt" 'Pro'
      assert_contains "$home_dir/out.txt" '39% used'
      assert_contains "$home_dir/out.txt" '            1d '
      assert_contains "$home_dir/out.txt" 'elapsed'
      assert_not_contains "$home_dir/out.txt" 'Flash'
      cat "$home_dir/out.txt"
      ;;
    no-pro-bucket)
      write_settings "$home_dir" oauth-personal
      write_creds "$home_dir" "$future_ms"
      write_quota_response_non_pro "$home_dir/quota-response.json"
      run_script "$home_dir" no-pro-bucket
      grep -Fx "$INVALID_USAGE_MSG" "$home_dir/out.txt" >/dev/null
      cat "$home_dir/out.txt"
      ;;
    expired-token-refresh)
      write_settings "$home_dir" oauth-personal
      write_creds "$home_dir" $((now_ms - 1000))
      run_script "$home_dir" expired-token-refresh
      assert_contains "$home_dir/curl-capture.txt" 'CALL_TYPE=refresh'
      assert_contains "$home_dir/curl-capture.txt" 'URL=https://oauth2.googleapis.com/token'
      assert_contains "$home_dir/curl-capture.txt" 'grant_type=refresh_token'
      assert_contains "$home_dir/out.txt" '39% used'
      assert_contains "$home_dir/.gemini/oauth_creds.json" 'rotated-refresh-token'
      ;;
    auth-rejected)
      write_settings "$home_dir" oauth-personal
      write_creds "$home_dir" "$future_ms"
      if run_script "$home_dir" auth-rejected; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "$AUTH_REJECTED_MSG"
      cat "$home_dir/err.txt"
      ;;
    network-error)
      write_settings "$home_dir" oauth-personal
      write_creds "$home_dir" "$future_ms"
      if run_script "$home_dir" network-error; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "$NETWORK_ERR_MSG"
      cat "$home_dir/err.txt"
      ;;
    empty-response)
      write_settings "$home_dir" oauth-personal
      write_creds "$home_dir" "$future_ms"
      run_script "$home_dir" empty-response
      grep -Fx "$INVALID_USAGE_MSG" "$home_dir/out.txt" >/dev/null
      cat "$home_dir/out.txt"
      ;;
    *)
      printf 'unknown scenario: %s\n' "$scenario" >&2
      return 1
      ;;
  esac

  assert_not_contains "$home_dir/out.txt" 'test-gemini-token'
  assert_not_contains "$home_dir/out.txt" 'test-refresh-token'
  assert_not_contains "$home_dir/err.txt" 'test-gemini-token'
  assert_not_contains "$home_dir/err.txt" 'test-refresh-token'

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

  printf 'PASS: %d/%d aitop-gemini scenarios\n' "$PASS_COUNT" "$TOTAL_COUNT"
}

main "$@"
