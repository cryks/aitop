#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
SCRIPT="$ROOT/aitop-copilot"
INSTALLED_SCRIPT="${AITOP_COPILOT_INSTALLED_SCRIPT:-${HOME}/bin/aitop-copilot}"

PASS_COUNT=0
TOTAL_COUNT=0

scenario_list=(
  missing-auth
  env-token
  backend-rejected
  success-copilot
  success-copilot-chat-only
  success-copilot-premium-only
  not-found
  rate-limited
  unexpected-status
  transport-error
)

CRED_MISSING_MSG="GitHub Copilot token not found. Authenticate with GitHub Copilot first or set GITHUB_TOKEN environment variable."
AUTH_REJECTED_MSG="GitHub Copilot token was rejected. Re-authenticate or check token permissions."
NETWORK_ERR_MSG="GitHub Copilot usage fetch failed. Check network connectivity and try again."
INVALID_USAGE_MSG="GitHub Copilot usage details were not present in the response."

make_temp_home() {
  local base
  base="$(mktemp -d)"
  printf '%s' "$base"
}

setup_mock_curl() {
  local temp_dir="$1"
  mkdir -p "$temp_dir/mockbin"
  cat > "$temp_dir/mockbin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

body_file=""
write_out=""
method="GET"
url=""
auth_header=""
accept_header=""
editor_version_header=""
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
    -X)
      method="$2"
      shift 2
      ;;
    -H)
      case "$2" in
        Authorization:*) auth_header="$2" ;;
        Accept:*) accept_header="$2" ;;
        Editor-Version:*) editor_version_header="$2" ;;
        User-Agent:*) user_agent_header="$2" ;;
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

if [[ "${MOCK_CURL_BEHAVIOR:-}" == "transport-error" ]]; then
  exit 28
fi

call=1
if [[ -f "${MOCK_CURL_COUNTER:?}" ]]; then
  call=$(( $(cat "${MOCK_CURL_COUNTER:?}") + 1 ))
fi
printf '%s' "$call" > "${MOCK_CURL_COUNTER:?}"

{
  printf 'CALL=%s\n' "$call"
  printf 'METHOD=%s\n' "$method"
  printf 'URL=%s\n' "$url"
  printf 'AUTH_PRESENT=%s\n' "$( [[ -n "$auth_header" ]] && printf yes || printf no )"
  printf 'ACCEPT=%s\n' "$accept_header"
  printf 'EDITOR_VERSION=%s\n' "$editor_version_header"
  printf 'USER_AGENT=%s\n' "$user_agent_header"
} >> "${MOCK_CURL_CAPTURE:?}"

case "${MOCK_CURL_BEHAVIOR:-success-copilot}" in
  success-copilot)
    cat > "$body_file" <<'JSON'
{"copilot_plan":"pro","quota_reset_date":"2026-05-01","quota_snapshots":{"premium_interactions":{"percent_remaining":75.5,"unlimited":false},"chat":{"percent_remaining":90.0,"unlimited":false},"completions":{"percent_remaining":100.0,"unlimited":true}}}
JSON
    printf '200'
    ;;
  success-copilot-chat-only)
    cat > "$body_file" <<'JSON'
{"copilot_plan":"free","quota_reset_date":"2026-05-01","quota_snapshots":{"chat":{"percent_remaining":50.0,"unlimited":false}}}
JSON
    printf '200'
    ;;
  success-copilot-premium-only)
    cat > "$body_file" <<'JSON'
{"copilot_plan":"business","quota_reset_date":"2026-05-01","quota_snapshots":{"premium_interactions":{"percent_remaining":25.0,"unlimited":false}}}
JSON
    printf '200'
    ;;
  backend-rejected)
    printf '{"message":"Bad credentials"}' > "$body_file"
    printf '401'
    ;;
  not-found)
    printf '{"message":"Not Found"}' > "$body_file"
    printf '404'
    ;;
  rate-limited)
    printf '{"message":"API rate limit exceeded"}' > "$body_file"
    printf '429'
    ;;
  unexpected-status)
    printf '{"message":"Internal Server Error"}' > "$body_file"
    printf '500'
    ;;
  *)
    printf '{}' > "$body_file"
    printf '200'
    ;;
esac
EOF
  chmod +x "$temp_dir/mockbin/curl"
}

run_script() {
  local home_dir="$1"
  local behavior="$2"
  local use_installed="${3:-no}"
  local env_token="${4:-}"
  local capture_file="$home_dir/curl-capture.txt"
  local counter_file="$home_dir/curl-counter.txt"
  local out_file="$home_dir/out.txt"
  local err_file="$home_dir/err.txt"
  local script_path="$SCRIPT"

  if [[ "$use_installed" == "yes" ]]; then
    script_path="$INSTALLED_SCRIPT"
  fi

  setup_mock_curl "$home_dir"
  
  local env_vars=""
  if [[ -n "$env_token" ]]; then
    env_vars="GITHUB_TOKEN=$env_token"
  fi
  
  if [[ -n "$env_vars" ]]; then
    PATH="$home_dir/mockbin:$PATH" MOCK_CURL_BEHAVIOR="$behavior" MOCK_CURL_CAPTURE="$capture_file" MOCK_CURL_COUNTER="$counter_file" HOME="$home_dir" eval "$env_vars" "$script_path" >"$out_file" 2>"$err_file" || return $?
  else
    PATH="$home_dir/mockbin:$PATH" MOCK_CURL_BEHAVIOR="$behavior" MOCK_CURL_CAPTURE="$capture_file" MOCK_CURL_COUNTER="$counter_file" HOME="$home_dir" "$script_path" >"$out_file" 2>"$err_file" || return $?
  fi
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
  local home_dir
  home_dir="$(make_temp_home)"

  case "$scenario" in
    missing-auth)
      if HOME="$home_dir" "$SCRIPT" >"$home_dir/out.txt" 2>"$home_dir/err.txt"; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "$CRED_MISSING_MSG"
      ;;
    env-token)
      run_script "$home_dir" "success-copilot" "no" "ghp_testtoken123"
      assert_contains "$home_dir/curl-capture.txt" 'AUTH_PRESENT=yes'
      assert_contains "$home_dir/out.txt" '* Copilot'
      assert_contains "$home_dir/out.txt" 'pro'
      assert_contains "$home_dir/out.txt" '25% used'
      assert_contains "$home_dir/out.txt" '10% used'
      ;;
    backend-rejected)
      if run_script "$home_dir" "backend-rejected" "no" "invalid-token"; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "$AUTH_REJECTED_MSG"
      ;;
    success-copilot)
      run_script "$home_dir" "success-copilot" "no" "test-token"
      assert_contains "$home_dir/curl-capture.txt" 'METHOD=GET'
      assert_contains "$home_dir/curl-capture.txt" 'AUTH_PRESENT=yes'
      assert_contains "$home_dir/curl-capture.txt" 'URL=https://api.github.com/copilot_internal/user'
      assert_contains "$home_dir/out.txt" '* Copilot'
      assert_contains "$home_dir/out.txt" 'pro'
      assert_contains "$home_dir/out.txt" 'Premium'
      assert_contains "$home_dir/out.txt" '25% used'
      assert_contains "$home_dir/out.txt" 'Chat'
      assert_contains "$home_dir/out.txt" '10% used'
      # Completions is unlimited, so should not appear
      assert_not_contains "$home_dir/out.txt" 'Completions'
      assert_not_contains "$home_dir/out.txt" '75.5'
      assert_not_contains "$home_dir/out.txt" '90.0'
      cat "$home_dir/out.txt"
      ;;
    success-copilot-chat-only)
      run_script "$home_dir" "success-copilot-chat-only" "no" "test-token"
      assert_contains "$home_dir/out.txt" '* Copilot'
      assert_contains "$home_dir/out.txt" 'free'
      assert_contains "$home_dir/out.txt" 'Chat'
      assert_contains "$home_dir/out.txt" '50% used'
      assert_not_contains "$home_dir/out.txt" 'Premium'
      cat "$home_dir/out.txt"
      ;;
    success-copilot-premium-only)
      run_script "$home_dir" "success-copilot-premium-only" "no" "test-token"
      assert_contains "$home_dir/out.txt" '* Copilot'
      assert_contains "$home_dir/out.txt" 'business'
      assert_contains "$home_dir/out.txt" 'Premium'
      assert_contains "$home_dir/out.txt" '75% used'
      assert_not_contains "$home_dir/out.txt" 'Chat'
      cat "$home_dir/out.txt"
      ;;
    not-found)
      if run_script "$home_dir" "not-found" "no" "test-token"; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "GitHub Copilot API not found"
      cat "$home_dir/err.txt"
      ;;
    rate-limited)
      if run_script "$home_dir" "rate-limited" "no" "test-token"; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "rate limited"
      cat "$home_dir/err.txt"
      ;;
    unexpected-status)
      if run_script "$home_dir" "unexpected-status" "no" "test-token"; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "Unexpected status: 500"
      cat "$home_dir/err.txt"
      ;;
    transport-error)
      if run_script "$home_dir" "transport-error" "no" "test-token"; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "$NETWORK_ERR_MSG"
      cat "$home_dir/err.txt"
      ;;
    *)
      printf 'unknown scenario: %s\n' "$scenario" >&2
      return 1
      ;;
  esac

  assert_not_contains "$home_dir/out.txt" 'test-token'
  assert_not_contains "$home_dir/err.txt" 'test-token'

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

  printf 'PASS: %d/%d aitop-copilot scenarios\n' "$PASS_COUNT" "$TOTAL_COUNT"
}

main "$@"
