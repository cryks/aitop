#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
SCRIPT="$ROOT/aitop-codex"
FIXTURES_DIR="$ROOT/tests/fixtures"
INSTALLED_SCRIPT="${AITOP_CODEX_INSTALLED_SCRIPT:-${HOME}/bin/aitop-codex}"

PASS_COUNT=0
TOTAL_COUNT=0

scenario_list=(
  missing-auth
  malformed-json
  incomplete-openai
  expired-token
  valid-auth-reaches-probe
  valid-auth-without-account-id-reaches-probe
  pool-dedupe-without-auth-account-id
  request-contract
  success-codex-headers
  success-with-pool-accounts
  success-generic-headers
  success-no-headers
  backend-rejected
  usage-limit
  unexpected-status
  transport-error
  expired-token-installed
)

AUTH_EXPIRED_MSG="OpenAI auth is missing or expired. Re-authenticate using the existing OpenCode login flow."
AUTH_INVALID_MSG="OpenAI auth file is invalid."
AUTH_INCOMPLETE_MSG="OpenAI auth entry is incomplete."
AUTH_REJECTED_MSG="OpenAI auth was rejected by the Codex backend. Check account access, region support, or re-authenticate."
NETWORK_ERR_MSG="Codex usage fetch failed. Check network connectivity and try again."
INVALID_USAGE_MSG="Codex usage details were not present in the response."

make_temp_home() {
  local base
  base="$(mktemp -d)"
  mkdir -p "$base/.local/share/opencode"
  printf '%s' "$base"
}

write_auth() {
  local home_dir="$1"
  local expires_ms="$2"
  local account_id="${3:-acct-test}"
  cat > "$home_dir/.local/share/opencode/auth.json" <<EOF
{
  "openai": {
    "type": "oauth",
    "access": "test-access-token",
    "refresh": "test-refresh-token",
    "expires": ${expires_ms},
    "accountId": "${account_id}"
  }
}
EOF
}

write_auth_without_account_id() {
  local home_dir="$1"
  local expires_ms="$2"
  cat > "$home_dir/.local/share/opencode/auth.json" <<EOF
{
  "openai": {
    "type": "oauth",
    "access": "test-access-token",
    "refresh": "test-refresh-token",
    "expires": ${expires_ms}
  }
}
EOF
}

write_pool_db() {
  local home_dir="$1"
  local expires_ms="$2"
  local account_id="${3:-acct-pool-1}"
  local db_path="$home_dir/.local/share/opencode/codex-pool.db"

  sqlite3 "$db_path" <<EOF
CREATE TABLE account (
  id TEXT PRIMARY KEY,
  subject TEXT,
  email TEXT,
  chatgpt_account_id TEXT,
  label TEXT,
  priority INTEGER NOT NULL UNIQUE,
  primary_account INTEGER NOT NULL DEFAULT 0,
  access_token TEXT NOT NULL,
  refresh_token TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  disabled_at INTEGER,
  last_error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
INSERT INTO account (
  id,
  subject,
  email,
  chatgpt_account_id,
  label,
  priority,
  primary_account,
  access_token,
  refresh_token,
  expires_at,
  disabled_at,
  last_error,
  created_at,
  updated_at
) VALUES (
  'pool-1',
  NULL,
  'pool@example.com',
  '${account_id}',
  NULL,
  1,
  0,
  'pool-access-token',
  'pool-refresh-token',
  ${expires_ms},
  NULL,
  NULL,
  ${expires_ms},
  ${expires_ms}
);
EOF
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
data=""
auth_header=""
accept_header=""
account_id_header=""
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
        ChatGPT-Account-Id:*) account_id_header="$2" ;;
        User-Agent:*) user_agent_header="$2" ;;
      esac
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
  printf 'ACCOUNT_ID=%s\n' "$account_id_header"
  printf 'USER_AGENT=%s\n' "$user_agent_header"
  printf 'DATA=%s\n\n' "$data"
} >> "${MOCK_CURL_CAPTURE:?}"

case "${MOCK_CURL_BEHAVIOR:-success-codex-headers}" in
  success-codex-headers)
    cat > "$body_file" <<'JSON'
{"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":12.5,"limit_window_seconds":600,"reset_at":1704069000},"secondary_window":{"used_percent":40.0,"limit_window_seconds":3600,"reset_at":1704074400}},"credits":{"has_credits":false,"unlimited":false,"balance":"0"}}
JSON
    printf '200'
    ;;
  success-with-pool-accounts)
    case "$account_id_header" in
      '')
        cat > "$body_file" <<'JSON'
{"account_id":"acct-test","plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":12.5,"limit_window_seconds":600,"reset_after_seconds":300},"secondary_window":{"used_percent":40.0,"limit_window_seconds":3600,"reset_after_seconds":1200}},"credits":{"has_credits":false,"unlimited":false,"balance":"0"}}
JSON
        printf '200'
        ;;
      'ChatGPT-Account-Id: acct-test')
        cat > "$body_file" <<'JSON'
{"account_id":"acct-test","plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":12.5,"limit_window_seconds":600,"reset_after_seconds":300},"secondary_window":{"used_percent":40.0,"limit_window_seconds":3600,"reset_after_seconds":1200}},"credits":{"has_credits":false,"unlimited":false,"balance":"0"}}
JSON
        printf '200'
        ;;
      'ChatGPT-Account-Id: acct-pool-1')
        cat > "$body_file" <<'JSON'
{"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":25,"limit_window_seconds":600,"reset_after_seconds":60},"secondary_window":{"used_percent":75,"limit_window_seconds":3600,"reset_after_seconds":900}},"credits":{"has_credits":false,"unlimited":false,"balance":"0"}}
JSON
        printf '200'
        ;;
      *)
        printf '{"error":{"message":"unknown account"}}' > "$body_file"
        printf '404'
        ;;
    esac
    ;;
  success-generic-headers)
    cat > "$body_file" <<'JSON'
{"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":59,"limit_window_seconds":1,"reset_after_seconds":1},"secondary_window":null},"credits":{"has_credits":true,"unlimited":false,"balance":"149984"}}
JSON
    printf '200'
    ;;
  success-no-headers)
    printf '{}' > "$body_file"
    printf '200'
    ;;
  backend-rejected)
    printf '{"error":{"message":"Workspace is not authorized in this region."}}' > "$body_file"
    printf '401'
    ;;
  usage-limit)
    cat > "$body_file" <<'JSON'
{"plan_type":"pro","rate_limit":{"allowed":false,"limit_reached":true,"primary_window":{"used_percent":100.0,"limit_window_seconds":900,"reset_after_seconds":1234,"reset_at":1704067242},"secondary_window":{"used_percent":87.5,"limit_window_seconds":3600,"reset_after_seconds":1234,"reset_at":1704067242}},"credits":{"has_credits":false,"unlimited":false,"balance":"0"}}
JSON
    printf '200'
    ;;
  unexpected-status)
    printf '{"error":{"message":"boom"}}' > "$body_file"
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
  local capture_file="$home_dir/curl-capture.txt"
  local counter_file="$home_dir/curl-counter.txt"
  local out_file="$home_dir/out.txt"
  local err_file="$home_dir/err.txt"
  local script_path="$SCRIPT"

  if [[ "$use_installed" == "yes" ]]; then
    script_path="$INSTALLED_SCRIPT"
  fi

  setup_mock_curl "$home_dir"
  PATH="$home_dir/mockbin:$PATH" MOCK_CURL_BEHAVIOR="$behavior" MOCK_CURL_CAPTURE="$capture_file" MOCK_CURL_COUNTER="$counter_file" HOME="$home_dir" "$script_path" >"$out_file" 2>"$err_file" || return $?
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

  case "$scenario" in
    missing-auth)
      if HOME="$home_dir" "$SCRIPT" >"$home_dir/out.txt" 2>"$home_dir/err.txt"; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "$AUTH_EXPIRED_MSG"
      ;;
    malformed-json)
      printf '{invalid json' > "$home_dir/.local/share/opencode/auth.json"
      if HOME="$home_dir" "$SCRIPT" >"$home_dir/out.txt" 2>"$home_dir/err.txt"; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "$AUTH_INVALID_MSG"
      ;;
    incomplete-openai)
      cat > "$home_dir/.local/share/opencode/auth.json" <<'EOF'
{"openai":{"type":"oauth","access":"x"}}
EOF
      if HOME="$home_dir" "$SCRIPT" >"$home_dir/out.txt" 2>"$home_dir/err.txt"; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "$AUTH_INCOMPLETE_MSG"
      ;;
    expired-token)
      write_auth "$home_dir" $((now_ms - 1000))
      if HOME="$home_dir" "$SCRIPT" >"$home_dir/out.txt" 2>"$home_dir/err.txt"; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "$AUTH_EXPIRED_MSG"
      ;;
    valid-auth-reaches-probe)
      write_auth "$home_dir" "$future_ms"
      run_script "$home_dir" "success-codex-headers"
      assert_contains "$home_dir/curl-capture.txt" 'METHOD=GET'
      assert_contains "$home_dir/curl-capture.txt" 'AUTH_PRESENT=yes'
      assert_contains "$home_dir/curl-capture.txt" 'ACCOUNT_ID=ChatGPT-Account-Id: acct-test'
      ;; 
    valid-auth-without-account-id-reaches-probe)
      write_auth_without_account_id "$home_dir" "$future_ms"
      run_script "$home_dir" "success-codex-headers"
      assert_contains "$home_dir/curl-capture.txt" 'METHOD=GET'
      assert_contains "$home_dir/curl-capture.txt" 'AUTH_PRESENT=yes'
      assert_contains "$home_dir/curl-capture.txt" 'ACCOUNT_ID='
      ;;
    pool-dedupe-without-auth-account-id)
      write_auth_without_account_id "$home_dir" "$future_ms"
      write_pool_db "$home_dir" "$future_ms" acct-test
      run_script "$home_dir" "success-with-pool-accounts"
      [[ "$(grep -c '^CALL=' "$home_dir/curl-capture.txt")" == "1" ]]
      assert_contains "$home_dir/out.txt" 'pro        '
      ;;
    request-contract)
      write_auth "$home_dir" "$future_ms"
      run_script "$home_dir" "success-codex-headers"
      assert_contains "$home_dir/curl-capture.txt" 'URL=https://chatgpt.com/backend-api/wham/usage'
      assert_contains "$home_dir/curl-capture.txt" 'METHOD=GET'
      assert_contains "$home_dir/curl-capture.txt" 'ACCEPT=Accept: application/json'
      assert_contains "$home_dir/curl-capture.txt" 'ACCOUNT_ID=ChatGPT-Account-Id: acct-test'
      assert_contains "$home_dir/curl-capture.txt" 'USER_AGENT=User-Agent: aitop-codex'
      assert_contains "$home_dir/curl-capture.txt" 'DATA='
      cat "$home_dir/curl-capture.txt"
      ;;
    success-codex-headers)
      write_auth "$home_dir" "$future_ms"
      run_script "$home_dir" "success-codex-headers"
      assert_contains "$home_dir/out.txt" '* Codex'
      assert_contains "$home_dir/out.txt" 'Primary'
      assert_contains "$home_dir/out.txt" 'pro        '
      assert_contains "$home_dir/out.txt" '13% used'
      assert_contains "$home_dir/out.txt" '10m window'
      assert_contains "$home_dir/out.txt" 'Secondary'
      assert_contains "$home_dir/out.txt" '40% used'
      assert_contains "$home_dir/out.txt" '1h window'
      assert_not_contains "$home_dir/out.txt" '1704069000'
      cat "$home_dir/out.txt"
      ;;
    success-with-pool-accounts)
      write_auth "$home_dir" "$future_ms"
      write_pool_db "$home_dir" "$future_ms"
      run_script "$home_dir" "success-with-pool-accounts"
      assert_contains "$home_dir/out.txt" '* Codex'
      assert_contains "$home_dir/out.txt" 'Primary'
      assert_contains "$home_dir/out.txt" 'pro        '
      assert_contains "$home_dir/out.txt" 'plus       '
      assert_contains "$home_dir/out.txt" 'Secondary'
      assert_contains "$home_dir/out.txt" '13% used'
      assert_contains "$home_dir/out.txt" '25% used'
      assert_contains "$home_dir/out.txt" '75% used'
      assert_not_contains "$home_dir/out.txt" 'pool@example.com'
      assert_contains "$home_dir/curl-capture.txt" 'ACCOUNT_ID=ChatGPT-Account-Id: acct-test'
      assert_contains "$home_dir/curl-capture.txt" 'ACCOUNT_ID=ChatGPT-Account-Id: acct-pool-1'
      cat "$home_dir/out.txt"
      ;;
    success-generic-headers)
      write_auth "$home_dir" "$future_ms"
      run_script "$home_dir" "success-generic-headers"
      assert_contains "$home_dir/out.txt" '* Codex'
      assert_contains "$home_dir/out.txt" 'plus       '
      assert_contains "$home_dir/out.txt" '59% used'
      assert_contains "$home_dir/out.txt" 'resets in              1s'
      assert_contains "$home_dir/out.txt" '            1s '
      assert_contains "$home_dir/out.txt" ' 0% elapsed'
      cat "$home_dir/out.txt"
      ;;
    success-no-headers)
      write_auth "$home_dir" "$future_ms"
      run_script "$home_dir" "success-no-headers"
      grep -Fx "$INVALID_USAGE_MSG" "$home_dir/out.txt" >/dev/null
      cat "$home_dir/out.txt"
      ;;
    backend-rejected)
      write_auth "$home_dir" "$future_ms"
      if run_script "$home_dir" "backend-rejected"; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "$AUTH_REJECTED_MSG"
      cat "$home_dir/err.txt"
      ;;
    usage-limit)
      write_auth "$home_dir" "$future_ms"
      run_script "$home_dir" "usage-limit"
      assert_contains "$home_dir/out.txt" '* Codex'
      assert_contains "$home_dir/out.txt" 'pro        '
      assert_contains "$home_dir/out.txt" '100% used'
      assert_contains "$home_dir/out.txt" 'full'
      assert_contains "$home_dir/out.txt" '15m window'
      assert_contains "$home_dir/out.txt" 'resets in         20m 34s'
      assert_contains "$home_dir/out.txt" 'Secondary'
      assert_contains "$home_dir/out.txt" '88% used'
      assert_contains "$home_dir/out.txt" '65% elapsed'
      cat "$home_dir/out.txt"
      ;;
    unexpected-status)
      write_auth "$home_dir" "$future_ms"
      if run_script "$home_dir" "unexpected-status"; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" 'Codex usage fetch failed. Unexpected backend status: 500.'
      cat "$home_dir/err.txt"
      ;;
    transport-error)
      write_auth "$home_dir" "$future_ms"
      if run_script "$home_dir" "transport-error"; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "$NETWORK_ERR_MSG"
      cat "$home_dir/err.txt"
      ;;
    expired-token-installed)
      write_auth "$home_dir" $((now_ms - 1000))
      if HOME="$home_dir" "$INSTALLED_SCRIPT" >"$home_dir/out.txt" 2>"$home_dir/err.txt"; then
        return 1
      fi
      assert_contains "$home_dir/err.txt" "$AUTH_EXPIRED_MSG"
      cat "$home_dir/err.txt"
      ;;
    *)
      printf 'unknown scenario: %s\n' "$scenario" >&2
      return 1
      ;;
  esac

  assert_not_contains "$home_dir/out.txt" 'Authorization:'
  assert_not_contains "$home_dir/out.txt" 'Bearer '
  assert_not_contains "$home_dir/out.txt" 'test-access-token'
  assert_not_contains "$home_dir/out.txt" 'test-refresh-token'
  assert_not_contains "$home_dir/err.txt" 'Authorization:'
  assert_not_contains "$home_dir/err.txt" 'Bearer '
  assert_not_contains "$home_dir/err.txt" 'test-access-token'
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

  mkdir -p "$FIXTURES_DIR"

  local scenario
  for scenario in "${requested[@]}"; do
    run_scenario "$scenario"
  done

  if [[ $# -eq 4 && "$1 $2 $3 $4" == "missing-auth expired-token malformed-json incomplete-openai" ]]; then
    printf 'PASS: auth scenarios\n'
    exit 0
  fi

  printf 'PASS: %d/%d aitop-codex scenarios\n' "$PASS_COUNT" "$TOTAL_COUNT"
}

main "$@"
