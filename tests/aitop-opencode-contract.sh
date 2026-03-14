#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
SCRIPT="$ROOT/aitop-opencode"

PASS_COUNT=0
TOTAL_COUNT=0

scenario_list=(
  missing-cookie
  cookie-invalid
  cookie-bare-value
  cookie-from-env
  request-contract
  workspace-seroval-get-fallback
  usage-get-500-post-fallback
  usage-seroval-null-billing-fallback
  costs-workspace-page-fallback
  auth-rejected-workspace
  auth-rejected-usage
  workspace-signin-page
  success-json
  success-high-usage
  success-weekly-only
  long-model-name-truncation
  zero-usage-model-hidden
  success-usage-summary-no-billing
  success-colored-summary
  network-error
  empty-response
)

COOKIE_MISSING_MSG="OpenCode cookie not found. Place your opencode.ai auth cookie in"
COOKIE_INVALID_MSG="OpenCode cookie is invalid. Ensure it contains an 'auth' cookie value."
WORKSPACE_ERR_MSG="Failed to fetch OpenCode workspace. Check your cookie or network."
USAGE_ERR_MSG="Failed to fetch OpenCode usage data."
NETWORK_ERR_MSG="OpenCode request failed. Check network connectivity and try again."
AUTH_REJECTED_MSG="OpenCode session cookie is invalid or expired. Update your cookie."
INVALID_USAGE_MSG="OpenCode usage details were not present in the response."

WORKSPACE_SERVER_ID="def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
SUBSCRIPTION_SERVER_ID="7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4"
COSTS_SERVER_ID="15702f3a12ff8bff357f8c2aa154a17e65b746d5f6b96adc9002c86ee0c15205"

make_temp_dir() {
  local base
  base="$(mktemp -d)"
  mkdir -p "$base/mockbin" "$base/.config/aitop-opencode"
  printf '%s' "$base"
}

write_cookie() {
  local temp_dir="$1"
  local value="$2"
  printf '%s' "$value" > "$temp_dir/.config/aitop-opencode/cookie"
}

setup_mock_python3() {
  local temp_dir="$1"
  cat > "$temp_dir/mockbin/python3" <<'PYEOF'
#!/usr/bin/env bash
/usr/bin/python3 "$@"
PYEOF
  chmod +x "$temp_dir/mockbin/python3"
}

setup_mock_curl() {
  local temp_dir="$1"
  cat > "$temp_dir/mockbin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

body_file=""
write_out=""
url=""
cookie_header=""
server_id_header=""
user_agent_header=""
origin_header=""
referer_header=""
method="GET"
request_data=""

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
        Cookie:*)       cookie_header="$2" ;;
        X-Server-Id:*)  server_id_header="$2" ;;
        User-Agent:*)   user_agent_header="$2" ;;
        Origin:*)       origin_header="$2" ;;
        Referer:*)      referer_header="$2" ;;
      esac
      shift 2
      ;;
    -X)
      method="$2"
      shift 2
      ;;
    --data)
      request_data="$2"
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

call_type="unknown"
if [[ "$url" == *"${MOCK_WORKSPACE_SERVER_ID}"* ]]; then
  call_type="workspace"
elif [[ "$url" == *"${MOCK_SUBSCRIPTION_SERVER_ID}"* ]]; then
  call_type="usage"
elif [[ "$url" == *"${MOCK_COSTS_SERVER_ID}"* ]]; then
  call_type="costs"
elif [[ "$url" == *"/workspace/"*"/billing" ]]; then
  call_type="billing"
elif [[ "$url" == *"/workspace/"*"/go" ]]; then
  call_type="go-page"
elif [[ "$url" == *"/workspace/"*"/usage" ]]; then
  call_type="usage-page"
elif [[ "$url" == *"/workspace/"* ]]; then
  call_type="workspace-page"
elif [[ "$server_id_header" == "X-Server-Id: ${MOCK_WORKSPACE_SERVER_ID}" ]]; then
  call_type="workspace"
elif [[ "$server_id_header" == "X-Server-Id: ${MOCK_SUBSCRIPTION_SERVER_ID}" ]]; then
  call_type="usage"
elif [[ "$server_id_header" == "X-Server-Id: ${MOCK_COSTS_SERVER_ID}" ]]; then
  call_type="costs"
fi

{
  printf 'CALL_TYPE=%s\n' "$call_type"
  printf 'URL=%s\n' "$url"
  printf 'METHOD=%s\n' "$method"
  printf 'DATA=%s\n' "$request_data"
  printf 'COOKIE=%s\n' "$cookie_header"
  printf 'SERVER_ID=%s\n' "$server_id_header"
  printf 'USER_AGENT=%s\n' "$user_agent_header"
  printf 'ORIGIN=%s\n' "$origin_header"
  printf 'REFERER=%s\n' "$referer_header"
} >> "${MOCK_CURL_CAPTURE:?}"

case "$call_type" in
  workspace)
    case "${MOCK_CURL_BEHAVIOR:-success}" in
      auth-rejected-workspace)
        printf '{"error":"unauthorized"}' > "$body_file"
        printf '401'
        ;;
      workspace-signin-page)
        printf '<html><body>Please <a href="/auth/authorize">sign in</a></body></html>' > "$body_file"
        printf '200'
        ;;
      *)
        cat "${MOCK_WORKSPACE_RESPONSE:?}" > "$body_file"
        printf '200'
        ;;
    esac
    ;;
  usage)
    case "${MOCK_CURL_BEHAVIOR:-success}" in
      auth-rejected-usage)
        printf '{"error":"unauthorized"}' > "$body_file"
        printf '403'
        ;;
      usage-get-500-post-fallback)
        if [[ "$method" == "GET" ]]; then
          printf '{"error":"HTTPError"}' > "$body_file"
          printf '500'
        else
          cat "${MOCK_USAGE_RESPONSE:?}" > "$body_file"
          printf '200'
        fi
        ;;
      usage-seroval-null-billing-fallback)
        printf ';0x00000051;((self.$R=self.$R||{})["server-fn:test"]=[],null)' > "$body_file"
        printf '200'
        ;;
      empty-response)
        printf 'null' > "$body_file"
        printf '200'
        ;;
      *)
        cat "${MOCK_USAGE_RESPONSE:?}" > "$body_file"
        printf '200'
        ;;
    esac
    ;;
  costs)
    case "${MOCK_CURL_BEHAVIOR:-success}" in
      usage-seroval-null-billing-fallback)
        printf '{"error":"HTTPError"}' > "$body_file"
        printf '500'
        ;;
      costs-workspace-page-fallback)
        printf '{"error":"HTTPError"}' > "$body_file"
        printf '500'
        ;;
      *)
        cat "${MOCK_COSTS_RESPONSE:?}" > "$body_file"
        printf '200'
        ;;
    esac
    ;;
  billing)
    case "${MOCK_CURL_BEHAVIOR:-success}" in
      billing-unavailable)
        printf '<html><body>not found</body></html>' > "$body_file"
        printf '404'
        ;;
      *)
        cat "${MOCK_BILLING_RESPONSE:?}" > "$body_file"
        printf '200'
        ;;
    esac
    ;;
  go-page)
    case "${MOCK_CURL_BEHAVIOR:-success}" in
      usage-seroval-null-billing-fallback)
        printf '<html><body>not found</body></html>' > "$body_file"
        printf '404'
        ;;
      *)
        cat "${MOCK_GO_PAGE_RESPONSE:?}" > "$body_file"
        printf '200'
        ;;
    esac
    ;;
  usage-page)
    case "${MOCK_CURL_BEHAVIOR:-success}" in
      usage-seroval-null-billing-fallback)
        printf '<html><body>not found</body></html>' > "$body_file"
        printf '404'
        ;;
      *)
        cat "${MOCK_USAGE_PAGE_RESPONSE:?}" > "$body_file"
        printf '200'
        ;;
    esac
    ;;
  workspace-page)
    cat "${MOCK_WORKSPACE_PAGE_RESPONSE:?}" > "$body_file"
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

write_workspace_response() {
  local file="$1"
  cat > "$file" <<'EOF'
[{"id":"wrk_abc123def456","name":"My Workspace","plan":"lite"}]
EOF
}

write_workspace_response_seroval() {
  local file="$1"
  cat > "$file" <<'EOF'
;0x000000d5;((self.$R=self.$R||{})["server-fn:test"]=[],($R=>$R[0]=[$R[1]={id:"wrk_abc123def456",name:"My Workspace",slug:null}])($R["server-fn:test"]))
EOF
}

write_usage_response_normal() {
  local file="$1"
  cat > "$file" <<'EOF'
{"subscription":{"rollingUsage":{"usagePercent":15.0,"resetInSec":9000},"weeklyUsage":{"usagePercent":5.0,"resetInSec":302400},"monthlyUsage":{"usagePercent":0.0,"resetInSec":1296000}}}
EOF
}

write_usage_response_high() {
  local file="$1"
  cat > "$file" <<'EOF'
{"subscription":{"rollingUsage":{"usagePercent":92.5,"resetInSec":3600},"weeklyUsage":{"usagePercent":78.0,"resetInSec":86400},"monthlyUsage":{"usagePercent":45.0,"resetInSec":604800}}}
EOF
}

write_usage_response_weekly_only() {
  local file="$1"
  cat > "$file" <<'EOF'
{"subscription":{"rollingUsage":{"usagePercent":30.0,"resetInSec":12000},"weeklyUsage":{"usagePercent":10.0,"resetInSec":500000}}}
EOF
}

write_billing_response() {
  local file="$1"
  cat > "$file" <<'EOF'
<html><body>balance:100000000</body></html>
EOF
}

write_billing_response_live_like() {
  local file="$1"
  cat > "$file" <<'EOF'
<html><body>balance:3136360974,monthlyLimit:200,monthlyUsage:1027724148</body></html>
EOF
}

write_go_page_response_normal() {
  local file="$1"
  cat > "$file" <<'EOF'
<html><body>rollingUsage:$R[1]={status:"ok",resetInSec:9000,usagePercent:15},weeklyUsage:$R[2]={status:"ok",resetInSec:302400,usagePercent:5},monthlyUsage:$R[3]={status:"ok",resetInSec:1296000,usagePercent:0},balance:100000000,monthlyLimit:200,monthlyUsage:0</body></html>
EOF
}

write_go_page_response_high() {
  local file="$1"
  cat > "$file" <<'EOF'
<html><body>rollingUsage:$R[1]={status:"heavy",resetInSec:3600,usagePercent:92.5},weeklyUsage:$R[2]={status:"ok",resetInSec:86400,usagePercent:78},monthlyUsage:$R[3]={status:"ok",resetInSec:604800,usagePercent:45},balance:100000000,monthlyLimit:200,monthlyUsage:9000000000</body></html>
EOF
}

write_go_page_response_weekly_only() {
  local file="$1"
  cat > "$file" <<'EOF'
<html><body>rollingUsage:$R[1]={status:"ok",resetInSec:12000,usagePercent:30},weeklyUsage:$R[2]={status:"ok",resetInSec:500000,usagePercent:10},balance:100000000,monthlyLimit:200,monthlyUsage:0</body></html>
EOF
}

write_go_page_response_live_like() {
  local file="$1"
  cat > "$file" <<'EOF'
<html><body>rollingUsage:$R[28]={status:"ok",resetInSec:16231,usagePercent:6},weeklyUsage:$R[29]={status:"ok",resetInSec:340600,usagePercent:32},monthlyUsage:$R[30]={status:"ok",resetInSec:1160570,usagePercent:25},balance:3136360974,monthlyLimit:200,monthlyUsage:1027724148</body></html>
EOF
}

write_usage_page_response_from_costs() {
  local file="$1"
  local today
  today="$(date -u '+%Y-%m-%d')"
  cat > "$file" <<EOF
<html><body>
id:"usg_1",workspaceID:"wrk_abc123def456",timeCreated:\$R[1]=new Date("${today}T01:15:44.000Z"),model:"gpt-5",provider:"openai",inputTokens:100,outputTokens:50,reasoningTokens:null,cacheReadTokens:0,cacheWrite5mTokens:null,cacheWrite1hTokens:null,cost:20000000,keyID:"key_1",sessionID:"ses_1",enrichment:\$R[2]={plan:"lite"}}
id:"usg_2",workspaceID:"wrk_abc123def456",timeCreated:\$R[3]=new Date("${today}T01:16:44.000Z"),model:"o3",provider:"openai",inputTokens:100,outputTokens:50,reasoningTokens:null,cacheReadTokens:0,cacheWrite5mTokens:null,cacheWrite1hTokens:null,cost:6000000,keyID:"key_2",sessionID:"ses_2",enrichment:\$R[4]={plan:"lite"}}
id:"usg_3",workspaceID:"wrk_abc123def456",timeCreated:\$R[5]=new Date("2026-03-01T01:16:44.000Z"),model:"gpt-5",provider:"openai",inputTokens:100,outputTokens:50,reasoningTokens:null,cacheReadTokens:0,cacheWrite5mTokens:null,cacheWrite1hTokens:null,cost:10000000,keyID:"key_3",sessionID:"ses_3",enrichment:\$R[6]={plan:"lite"}}
id:"usg_4",workspaceID:"wrk_abc123def456",timeCreated:\$R[7]=new Date("${today}T01:16:44.000Z"),model:"gpt-5",provider:"openai",inputTokens:100,outputTokens:50,reasoningTokens:null,cacheReadTokens:0,cacheWrite5mTokens:null,cacheWrite1hTokens:null,cost:110000000,keyID:"key_4",sessionID:"ses_4",enrichment:\$R[8]={plan:null}}
id:"usg_5",workspaceID:"wrk_abc123def456",timeCreated:\$R[9]=new Date("${today}T01:16:44.000Z"),model:"o3",provider:"openai",inputTokens:100,outputTokens:50,reasoningTokens:null,cacheReadTokens:0,cacheWrite5mTokens:null,cacheWrite1hTokens:null,cost:30000000,keyID:"key_5",sessionID:"ses_5",enrichment:\$R[10]={plan:null}}
id:"usg_6",workspaceID:"wrk_abc123def456",timeCreated:\$R[11]=new Date("2026-03-01T01:16:44.000Z"),model:"gpt-5",provider:"openai",inputTokens:100,outputTokens:50,reasoningTokens:null,cacheReadTokens:0,cacheWrite5mTokens:null,cacheWrite1hTokens:null,cost:20000000,keyID:"key_6",sessionID:"ses_6",enrichment:\$R[12]={plan:null}}
</body></html>
EOF
}

write_workspace_page_response_live_like() {
  local file="$1"
  cat > "$file" <<'EOF'
<html><body>id:"usg_1",workspaceID:"wrk_abc123def456",timeCreated:$R[1]=new Date("2026-03-12T01:15:44.000Z"),model:"gpt-5",provider:"openai",inputTokens:100,outputTokens:50,reasoningTokens:null,cacheReadTokens:0,cacheWrite5mTokens:null,cacheWrite1hTokens:null,cost:20000000,keyID:"key_1",sessionID:"ses_1",enrichment:$R[2]={plan:"lite"}} id:"usg_2",workspaceID:"wrk_abc123def456",timeCreated:$R[3]=new Date("2026-03-12T01:16:44.000Z"),model:"o3",provider:"openai",inputTokens:100,outputTokens:50,reasoningTokens:null,cacheReadTokens:0,cacheWrite5mTokens:null,cacheWrite1hTokens:null,cost:6000000,keyID:"key_2",sessionID:"ses_2",enrichment:$R[4]={plan:"lite"}}</body></html>
EOF
}

write_costs_response() {
  local file="$1"
  local today
  today="$(date -u '+%Y-%m-%d')"
  cat > "$file" <<EOF
  [{date:"${today}",model:"gpt-5",totalCost:20000000,keyId:"key_1",plan:"lite"},{date:"${today}",model:"o3",totalCost:6000000,keyId:"key_2",plan:"lite"},{date:"2026-03-01",model:"gpt-5",totalCost:10000000,keyId:"key_3",plan:"lite"},{date:"${today}",model:"gpt-5",totalCost:110000000,keyId:"key_4",plan:null},{date:"${today}",model:"o3",totalCost:30000000,keyId:"key_5",plan:null},{date:"2026-03-01",model:"gpt-5",totalCost:20000000,keyId:"key_6",plan:null}]
EOF
}

write_costs_response_with_long_model() {
  local file="$1"
  local today
  today="$(date -u '+%Y-%m-%d')"
  cat > "$file" <<EOF
[{date:"${today}",model:"nemotron-3-super-free",totalCost:20000000,keyId:"key_1",plan:"lite"},{date:"${today}",model:"o3",totalCost:6000000,keyId:"key_2",plan:null},{date:"2026-03-01",model:"nemotron-3-super-free",totalCost:10000000,keyId:"key_3",plan:"lite"}]
EOF
}

write_costs_response_with_zero_usage_model() {
  local file="$1"
  local today
  today="$(date -u '+%Y-%m-%d')"
  cat > "$file" <<EOF
[{date:"${today}",model:"gpt-5",totalCost:20000000,keyId:"key_1",plan:"lite"},{date:"${today}",model:"gpt-5",totalCost:110000000,keyId:"key_2",plan:null},{date:"${today}",model:"o3",totalCost:0,keyId:"key_3",plan:"lite"},{date:"${today}",model:"o3",totalCost:0,keyId:"key_4",plan:null},{date:"2026-03-01",model:"gpt-5",totalCost:10000000,keyId:"key_5",plan:"lite"},{date:"2026-03-01",model:"gpt-5",totalCost:20000000,keyId:"key_6",plan:null},{date:"2026-03-01",model:"o3",totalCost:0,keyId:"key_7",plan:"lite"},{date:"2026-03-01",model:"o3",totalCost:0,keyId:"key_8",plan:null}]
EOF
}

run_script() {
  local temp_dir="$1"
  local curl_behavior="$2"
  local cookie_value="${3:-auth=test-cookie-token-xyz}"
  local go_page_variant="${4:-normal}"
  local out_file="$temp_dir/out.txt"
  local err_file="$temp_dir/err.txt"
  local capture_file="$temp_dir/curl-capture.txt"

  setup_mock_curl "$temp_dir"
  setup_mock_python3 "$temp_dir"
  write_cookie "$temp_dir" "$cookie_value"

  : > "$capture_file"

  write_billing_response "$temp_dir/billing-response.html"
  write_costs_response "$temp_dir/costs-response.txt"
  write_usage_page_response_from_costs "$temp_dir/usage-page-response.html"
  write_workspace_page_response_live_like "$temp_dir/workspace-page-response.html"

  case "$go_page_variant" in
    normal) write_go_page_response_normal "$temp_dir/go-page-response.html" ;;
    high) write_go_page_response_high "$temp_dir/go-page-response.html" ;;
    weekly-only) write_go_page_response_weekly_only "$temp_dir/go-page-response.html" ;;
    live-like) write_go_page_response_live_like "$temp_dir/go-page-response.html" ;;
    *) printf 'unknown go page variant: %s\n' "$go_page_variant" >&2; return 1 ;;
  esac

  HOME="$temp_dir" \
    PATH="$temp_dir/mockbin:$PATH" \
    AITOP_OPENCODE_WORKSPACE_ID="" \
    MOCK_CURL_BEHAVIOR="$curl_behavior" \
    MOCK_CURL_CAPTURE="$capture_file" \
    MOCK_WORKSPACE_RESPONSE="$temp_dir/workspace-response.json" \
    MOCK_USAGE_RESPONSE="$temp_dir/usage-response.json" \
    MOCK_BILLING_RESPONSE="$temp_dir/billing-response.html" \
    MOCK_GO_PAGE_RESPONSE="$temp_dir/go-page-response.html" \
    MOCK_USAGE_PAGE_RESPONSE="$temp_dir/usage-page-response.html" \
    MOCK_COSTS_RESPONSE="$temp_dir/costs-response.txt" \
    MOCK_WORKSPACE_PAGE_RESPONSE="$temp_dir/workspace-page-response.html" \
    MOCK_WORKSPACE_SERVER_ID="$WORKSPACE_SERVER_ID" \
    MOCK_SUBSCRIPTION_SERVER_ID="$SUBSCRIPTION_SERVER_ID" \
    MOCK_COSTS_SERVER_ID="$COSTS_SERVER_ID" \
    AITOP_OPENCODE_COOKIE="" \
    "$SCRIPT" >"$out_file" 2>"$err_file" || return $?
}

assert_contains() {
  local file="$1"
  local expected="$2"
  if ! grep -F "$expected" "$file" >/dev/null; then
    printf '  ASSERT FAILED: expected "%s" in %s\n' "$expected" "$file" >&2
    printf '  File contents:\n' >&2
    cat "$file" >&2
    return 1
  fi
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  ! grep -F "$needle" "$file" >/dev/null
}

assert_contains_ansi() {
  local file="$1"
  local expected="$2"
  if ! grep -F "$expected" "$file" >/dev/null; then
    printf '  ASSERT FAILED: expected ANSI sequence %q in %s\n' "$expected" "$file" >&2
    printf '  File contents:\n' >&2
    cat "$file" >&2
    return 1
  fi
}

record_pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
}

run_scenario() {
  local scenario="$1"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  local temp_dir
  temp_dir="$(make_temp_dir)"

  case "$scenario" in
    missing-cookie)
      setup_mock_curl "$temp_dir"
      setup_mock_python3 "$temp_dir"
      if HOME="$temp_dir" \
        PATH="$temp_dir/mockbin:$PATH" \
        AITOP_OPENCODE_WORKSPACE_ID="" \
        AITOP_OPENCODE_COOKIE="" \
        "$SCRIPT" >"$temp_dir/out.txt" 2>"$temp_dir/err.txt"; then
        printf '  ASSERT FAILED: expected nonzero exit\n' >&2
        return 1
      fi
      assert_contains "$temp_dir/err.txt" "$COOKIE_MISSING_MSG"
      ;;

    cookie-invalid)
      write_cookie "$temp_dir" "session_id=abc123"
      setup_mock_curl "$temp_dir"
      setup_mock_python3 "$temp_dir"
      if HOME="$temp_dir" \
        PATH="$temp_dir/mockbin:$PATH" \
        AITOP_OPENCODE_WORKSPACE_ID="" \
        AITOP_OPENCODE_COOKIE="" \
        "$SCRIPT" >"$temp_dir/out.txt" 2>"$temp_dir/err.txt"; then
        printf '  ASSERT FAILED: expected nonzero exit\n' >&2
        return 1
      fi
      assert_contains "$temp_dir/err.txt" "$COOKIE_INVALID_MSG"
      ;;

    cookie-bare-value)
      write_workspace_response "$temp_dir/workspace-response.json"
      write_usage_response_normal "$temp_dir/usage-response.json"
      run_script "$temp_dir" "success" "bare-token-value-no-equals"
      assert_contains "$temp_dir/curl-capture.txt" "Cookie: auth=bare-token-value-no-equals"
      ;;

    cookie-from-env)
      write_workspace_response "$temp_dir/workspace-response.json"
      write_usage_response_normal "$temp_dir/usage-response.json"
      setup_mock_curl "$temp_dir"
      setup_mock_python3 "$temp_dir"
      : > "$temp_dir/curl-capture.txt"
      write_billing_response "$temp_dir/billing-response.html"
      write_go_page_response_normal "$temp_dir/go-page-response.html"
      write_usage_page_response_from_costs "$temp_dir/usage-page-response.html"
      write_costs_response "$temp_dir/costs-response.txt"
      rm -f "$temp_dir/.config/aitop-opencode/cookie"
      HOME="$temp_dir" \
        PATH="$temp_dir/mockbin:$PATH" \
        AITOP_OPENCODE_WORKSPACE_ID="" \
        MOCK_CURL_BEHAVIOR="success" \
        MOCK_CURL_CAPTURE="$temp_dir/curl-capture.txt" \
        MOCK_WORKSPACE_RESPONSE="$temp_dir/workspace-response.json" \
        MOCK_USAGE_RESPONSE="$temp_dir/usage-response.json" \
        MOCK_BILLING_RESPONSE="$temp_dir/billing-response.html" \
        MOCK_GO_PAGE_RESPONSE="$temp_dir/go-page-response.html" \
        MOCK_USAGE_PAGE_RESPONSE="$temp_dir/usage-page-response.html" \
        MOCK_COSTS_RESPONSE="$temp_dir/costs-response.txt" \
        MOCK_WORKSPACE_SERVER_ID="$WORKSPACE_SERVER_ID" \
        MOCK_SUBSCRIPTION_SERVER_ID="$SUBSCRIPTION_SERVER_ID" \
        MOCK_COSTS_SERVER_ID="$COSTS_SERVER_ID" \
        AITOP_OPENCODE_COOKIE="auth=env-cookie-token" \
        "$SCRIPT" >"$temp_dir/out.txt" 2>"$temp_dir/err.txt"
      assert_contains "$temp_dir/curl-capture.txt" "Cookie: auth=env-cookie-token"
      assert_contains "$temp_dir/out.txt" "15% used"
      ;;

    request-contract)
      write_workspace_response "$temp_dir/workspace-response.json"
      write_usage_response_normal "$temp_dir/usage-response.json"
      run_script "$temp_dir" "success" "auth=test-cookie-token-xyz"
      assert_contains "$temp_dir/curl-capture.txt" "CALL_TYPE=workspace"
      assert_contains "$temp_dir/curl-capture.txt" "METHOD=GET"
      assert_contains "$temp_dir/curl-capture.txt" "Origin: https://opencode.ai"
      assert_contains "$temp_dir/curl-capture.txt" "Cookie: auth=test-cookie-token-xyz"
      assert_contains "$temp_dir/curl-capture.txt" "CALL_TYPE=go-page"
      assert_contains "$temp_dir/curl-capture.txt" "CALL_TYPE=usage-page"
      assert_contains "$temp_dir/curl-capture.txt" "CALL_TYPE=usage"
      assert_contains "$temp_dir/curl-capture.txt" "CALL_TYPE=costs"
      assert_contains "$temp_dir/curl-capture.txt" "Referer: https://opencode.ai/workspace/wrk_abc123def456/billing"
      assert_contains "$temp_dir/curl-capture.txt" "Referer: https://opencode.ai/workspace/wrk_abc123def456/usage"
      cat "$temp_dir/curl-capture.txt"
      ;;

    workspace-seroval-get-fallback)
      write_workspace_response_seroval "$temp_dir/workspace-response.json"
      write_usage_response_normal "$temp_dir/usage-response.json"
      run_script "$temp_dir" "success"
      assert_contains "$temp_dir/out.txt" '15% used'
      assert_not_contains "$temp_dir/curl-capture.txt" 'METHOD=POST'
      ;;

    usage-get-500-post-fallback)
      write_workspace_response "$temp_dir/workspace-response.json"
      write_usage_response_normal "$temp_dir/usage-response.json"
      run_script "$temp_dir" "usage-get-500-post-fallback"
      assert_contains "$temp_dir/curl-capture.txt" "CALL_TYPE=usage"
      assert_contains "$temp_dir/curl-capture.txt" "METHOD=POST"
      assert_contains "$temp_dir/curl-capture.txt" 'DATA=["wrk_abc123def456"]'
      assert_contains "$temp_dir/out.txt" '15% used'
      ;;

    usage-seroval-null-billing-fallback)
      write_workspace_response "$temp_dir/workspace-response.json"
      write_usage_response_normal "$temp_dir/usage-response.json"
      setup_mock_curl "$temp_dir"
      setup_mock_python3 "$temp_dir"
      write_cookie "$temp_dir" 'auth=test-cookie-token-xyz'
      : > "$temp_dir/curl-capture.txt"
      write_billing_response_live_like "$temp_dir/billing-response.html"
      write_costs_response "$temp_dir/costs-response.txt"
      write_workspace_page_response_live_like "$temp_dir/workspace-page-response.html"
      HOME="$temp_dir" \
        PATH="$temp_dir/mockbin:$PATH" \
        AITOP_OPENCODE_WORKSPACE_ID="" \
        MOCK_CURL_BEHAVIOR="usage-seroval-null-billing-fallback" \
        MOCK_CURL_CAPTURE="$temp_dir/curl-capture.txt" \
        MOCK_WORKSPACE_RESPONSE="$temp_dir/workspace-response.json" \
        MOCK_USAGE_RESPONSE="$temp_dir/usage-response.json" \
        MOCK_BILLING_RESPONSE="$temp_dir/billing-response.html" \
        MOCK_COSTS_RESPONSE="$temp_dir/costs-response.txt" \
        MOCK_WORKSPACE_PAGE_RESPONSE="$temp_dir/workspace-page-response.html" \
        MOCK_WORKSPACE_SERVER_ID="$WORKSPACE_SERVER_ID" \
        MOCK_SUBSCRIPTION_SERVER_ID="$SUBSCRIPTION_SERVER_ID" \
        MOCK_COSTS_SERVER_ID="$COSTS_SERVER_ID" \
        AITOP_OPENCODE_COOKIE="" \
        "$SCRIPT" >"$temp_dir/out.txt" 2>"$temp_dir/err.txt"
      assert_contains "$temp_dir/out.txt" '* OpenCode'
      assert_contains "$temp_dir/out.txt" 'Monthly'
      assert_contains "$temp_dir/out.txt" '6% used'
      assert_contains "$temp_dir/out.txt" '$31.36'
      assert_not_contains "$temp_dir/out.txt" '5-hour'
      ;;

    costs-workspace-page-fallback)
      write_workspace_response "$temp_dir/workspace-response.json"
      write_usage_response_normal "$temp_dir/usage-response.json"
      setup_mock_curl "$temp_dir"
      setup_mock_python3 "$temp_dir"
      write_cookie "$temp_dir" 'auth=test-cookie-token-xyz'
      : > "$temp_dir/curl-capture.txt"
      write_billing_response "$temp_dir/billing-response.html"
      write_costs_response "$temp_dir/costs-response.txt"
      write_workspace_page_response_live_like "$temp_dir/workspace-page-response.html"
      HOME="$temp_dir" \
        PATH="$temp_dir/mockbin:$PATH" \
        AITOP_OPENCODE_WORKSPACE_ID="" \
        MOCK_CURL_BEHAVIOR="costs-workspace-page-fallback" \
        MOCK_CURL_CAPTURE="$temp_dir/curl-capture.txt" \
        MOCK_WORKSPACE_RESPONSE="$temp_dir/workspace-response.json" \
        MOCK_USAGE_RESPONSE="$temp_dir/usage-response.json" \
        MOCK_BILLING_RESPONSE="$temp_dir/billing-response.html" \
        MOCK_COSTS_RESPONSE="$temp_dir/costs-response.txt" \
        MOCK_WORKSPACE_PAGE_RESPONSE="$temp_dir/workspace-page-response.html" \
        MOCK_WORKSPACE_SERVER_ID="$WORKSPACE_SERVER_ID" \
        MOCK_SUBSCRIPTION_SERVER_ID="$SUBSCRIPTION_SERVER_ID" \
        MOCK_COSTS_SERVER_ID="$COSTS_SERVER_ID" \
        AITOP_OPENCODE_COOKIE="" \
        "$SCRIPT" >"$temp_dir/out.txt" 2>"$temp_dir/err.txt"
      assert_contains "$temp_dir/out.txt" 'gpt-5         $0.20/'
      assert_contains "$temp_dir/out.txt" 'o3            $0.06/'
      ;;

    auth-rejected-workspace)
      write_workspace_response "$temp_dir/workspace-response.json"
      write_usage_response_normal "$temp_dir/usage-response.json"
      if run_script "$temp_dir" "auth-rejected-workspace"; then
        printf '  ASSERT FAILED: expected nonzero exit\n' >&2
        return 1
      fi
      assert_contains "$temp_dir/err.txt" "$AUTH_REJECTED_MSG"
      ;;

    auth-rejected-usage)
      write_workspace_response "$temp_dir/workspace-response.json"
      write_usage_response_normal "$temp_dir/usage-response.json"
      if run_script "$temp_dir" "auth-rejected-usage"; then
        printf '  ASSERT FAILED: expected nonzero exit\n' >&2
        return 1
      fi
      assert_contains "$temp_dir/err.txt" "$AUTH_REJECTED_MSG"
      ;;

    workspace-signin-page)
      write_workspace_response "$temp_dir/workspace-response.json"
      write_usage_response_normal "$temp_dir/usage-response.json"
      if run_script "$temp_dir" "workspace-signin-page"; then
        printf '  ASSERT FAILED: expected nonzero exit\n' >&2
        return 1
      fi
      assert_contains "$temp_dir/err.txt" "$AUTH_REJECTED_MSG"
      ;;

    success-json)
      write_workspace_response "$temp_dir/workspace-response.json"
      write_usage_response_normal "$temp_dir/usage-response.json"
      run_script "$temp_dir" "success"
      assert_contains "$temp_dir/out.txt" '* OpenCode'
      assert_contains "$temp_dir/out.txt" '15% used'
      assert_contains "$temp_dir/out.txt" 'resets in      2h 30m  0s'
      assert_contains "$temp_dir/out.txt" '            5h '
      assert_contains "$temp_dir/out.txt" ' 5% used'
      assert_contains "$temp_dir/out.txt" '50% elapsed'
      assert_contains "$temp_dir/out.txt" 'Today'
      assert_contains "$temp_dir/out.txt" 'Go/   Zen'
      assert_contains "$temp_dir/out.txt" 'This month'
      assert_contains "$temp_dir/out.txt" 'Balance'
      assert_contains "$temp_dir/out.txt" 'gpt-5         $0.20/ $1.10'
      assert_contains "$temp_dir/out.txt" 'gpt-5         $0.30/ $1.30'
      assert_contains "$temp_dir/out.txt" '        $1.00'
      assert_not_contains "$temp_dir/out.txt" 'Monthly'
      assert_not_contains "$temp_dir/out.txt" '$0.36/$1.00'
      cat "$temp_dir/out.txt"
      ;;

    success-high-usage)
      write_workspace_response "$temp_dir/workspace-response.json"
      write_usage_response_high "$temp_dir/usage-response.json"
      run_script "$temp_dir" "success" "auth=test-cookie-token-xyz" "high"
      assert_contains "$temp_dir/out.txt" '93% used'
      assert_contains "$temp_dir/out.txt" 'ahead'
      assert_contains "$temp_dir/out.txt" '78% used'
      assert_contains "$temp_dir/out.txt" '45% used'
      assert_contains "$temp_dir/out.txt" 'Monthly'
      assert_contains "$temp_dir/out.txt" 'resets in  7d  0h  0m  0s'
      assert_contains "$temp_dir/out.txt" 'total         $0.36/ $1.60'
      cat "$temp_dir/out.txt"
      ;;

    success-weekly-only)
      write_workspace_response "$temp_dir/workspace-response.json"
      write_usage_response_weekly_only "$temp_dir/usage-response.json"
      run_script "$temp_dir" "success" "auth=test-cookie-token-xyz" "weekly-only"
      assert_contains "$temp_dir/out.txt" '30% used'
      assert_contains "$temp_dir/out.txt" '10% used'
      assert_contains "$temp_dir/out.txt" 'o3            $0.06/ $0.30'
      assert_not_contains "$temp_dir/out.txt" 'Monthly'
      ;;

    long-model-name-truncation)
      write_workspace_response "$temp_dir/workspace-response.json"
      write_usage_response_normal "$temp_dir/usage-response.json"
      setup_mock_curl "$temp_dir"
      setup_mock_python3 "$temp_dir"
      write_cookie "$temp_dir" 'auth=test-cookie-token-xyz'
      : > "$temp_dir/curl-capture.txt"
      write_billing_response "$temp_dir/billing-response.html"
      write_go_page_response_normal "$temp_dir/go-page-response.html"
      write_usage_page_response_from_costs "$temp_dir/usage-page-response.html"
      write_costs_response_with_long_model "$temp_dir/costs-response.txt"
      write_workspace_page_response_live_like "$temp_dir/workspace-page-response.html"
      HOME="$temp_dir" \
        PATH="$temp_dir/mockbin:$PATH" \
        AITOP_OPENCODE_WORKSPACE_ID="" \
        MOCK_CURL_BEHAVIOR="success" \
        MOCK_CURL_CAPTURE="$temp_dir/curl-capture.txt" \
        MOCK_WORKSPACE_RESPONSE="$temp_dir/workspace-response.json" \
        MOCK_USAGE_RESPONSE="$temp_dir/usage-response.json" \
        MOCK_BILLING_RESPONSE="$temp_dir/billing-response.html" \
        MOCK_GO_PAGE_RESPONSE="$temp_dir/go-page-response.html" \
        MOCK_USAGE_PAGE_RESPONSE="$temp_dir/usage-page-response.html" \
        MOCK_COSTS_RESPONSE="$temp_dir/costs-response.txt" \
        MOCK_WORKSPACE_PAGE_RESPONSE="$temp_dir/workspace-page-response.html" \
        MOCK_WORKSPACE_SERVER_ID="$WORKSPACE_SERVER_ID" \
        MOCK_SUBSCRIPTION_SERVER_ID="$SUBSCRIPTION_SERVER_ID" \
        MOCK_COSTS_SERVER_ID="$COSTS_SERVER_ID" \
        AITOP_OPENCODE_COOKIE="" \
        "$SCRIPT" >"$temp_dir/out.txt" 2>"$temp_dir/err.txt"
      assert_contains "$temp_dir/out.txt" 'nemotron-...'
      assert_not_contains "$temp_dir/out.txt" 'nemotron-3-super-free'
      ;;

    zero-usage-model-hidden)
      write_workspace_response "$temp_dir/workspace-response.json"
      write_usage_response_normal "$temp_dir/usage-response.json"
      setup_mock_curl "$temp_dir"
      setup_mock_python3 "$temp_dir"
      write_cookie "$temp_dir" 'auth=test-cookie-token-xyz'
      : > "$temp_dir/curl-capture.txt"
      write_billing_response "$temp_dir/billing-response.html"
      write_go_page_response_normal "$temp_dir/go-page-response.html"
      write_usage_page_response_from_costs "$temp_dir/usage-page-response.html"
      write_costs_response_with_zero_usage_model "$temp_dir/costs-response.txt"
      write_workspace_page_response_live_like "$temp_dir/workspace-page-response.html"
      HOME="$temp_dir" \
        PATH="$temp_dir/mockbin:$PATH" \
        AITOP_OPENCODE_WORKSPACE_ID="" \
        MOCK_CURL_BEHAVIOR="success" \
        MOCK_CURL_CAPTURE="$temp_dir/curl-capture.txt" \
        MOCK_WORKSPACE_RESPONSE="$temp_dir/workspace-response.json" \
        MOCK_USAGE_RESPONSE="$temp_dir/usage-response.json" \
        MOCK_BILLING_RESPONSE="$temp_dir/billing-response.html" \
        MOCK_GO_PAGE_RESPONSE="$temp_dir/go-page-response.html" \
        MOCK_USAGE_PAGE_RESPONSE="$temp_dir/usage-page-response.html" \
        MOCK_COSTS_RESPONSE="$temp_dir/costs-response.txt" \
        MOCK_WORKSPACE_PAGE_RESPONSE="$temp_dir/workspace-page-response.html" \
        MOCK_WORKSPACE_SERVER_ID="$WORKSPACE_SERVER_ID" \
        MOCK_SUBSCRIPTION_SERVER_ID="$SUBSCRIPTION_SERVER_ID" \
        MOCK_COSTS_SERVER_ID="$COSTS_SERVER_ID" \
        AITOP_OPENCODE_COOKIE="" \
        "$SCRIPT" >"$temp_dir/out.txt" 2>"$temp_dir/err.txt"
      assert_contains "$temp_dir/out.txt" 'gpt-5         $0.20/ $1.10'
      assert_not_contains "$temp_dir/out.txt" 'o3            -/     -'
      ;;

    success-usage-summary-no-billing)
      write_workspace_response "$temp_dir/workspace-response.json"
      write_usage_response_normal "$temp_dir/usage-response.json"
      run_script "$temp_dir" "billing-unavailable"
      assert_contains "$temp_dir/out.txt" 'gpt-5         $0.20/ $1.10'
      assert_contains "$temp_dir/out.txt" '$1.00'
      ;;

    success-colored-summary)
      write_workspace_response "$temp_dir/workspace-response.json"
      write_usage_response_normal "$temp_dir/usage-response.json"
      setup_mock_curl "$temp_dir"
      setup_mock_python3 "$temp_dir"
      write_cookie "$temp_dir" 'auth=test-cookie-token-xyz'
      : > "$temp_dir/curl-capture.txt"
      write_billing_response "$temp_dir/billing-response.html"
      write_go_page_response_normal "$temp_dir/go-page-response.html"
      write_usage_page_response_from_costs "$temp_dir/usage-page-response.html"
      write_costs_response "$temp_dir/costs-response.txt"
      HOME="$temp_dir" \
        PATH="$temp_dir/mockbin:$PATH" \
        AITOP_OPENCODE_WORKSPACE_ID="" \
        MOCK_CURL_BEHAVIOR="success" \
        MOCK_CURL_CAPTURE="$temp_dir/curl-capture.txt" \
        MOCK_WORKSPACE_RESPONSE="$temp_dir/workspace-response.json" \
        MOCK_USAGE_RESPONSE="$temp_dir/usage-response.json" \
        MOCK_BILLING_RESPONSE="$temp_dir/billing-response.html" \
        MOCK_GO_PAGE_RESPONSE="$temp_dir/go-page-response.html" \
        MOCK_USAGE_PAGE_RESPONSE="$temp_dir/usage-page-response.html" \
        MOCK_COSTS_RESPONSE="$temp_dir/costs-response.txt" \
        MOCK_WORKSPACE_SERVER_ID="$WORKSPACE_SERVER_ID" \
        MOCK_SUBSCRIPTION_SERVER_ID="$SUBSCRIPTION_SERVER_ID" \
        MOCK_COSTS_SERVER_ID="$COSTS_SERVER_ID" \
        CLICOLOR_FORCE=1 \
        AITOP_OPENCODE_COOKIE="" \
        "$SCRIPT" >"$temp_dir/out.txt" 2>"$temp_dir/err.txt"
      assert_contains_ansi "$temp_dir/out.txt" $'\033[2m $0.20\033[0m/ $1.10'
      ;;

    network-error)
      write_workspace_response "$temp_dir/workspace-response.json"
      write_usage_response_normal "$temp_dir/usage-response.json"
      if run_script "$temp_dir" "network-error"; then
        printf '  ASSERT FAILED: expected nonzero exit\n' >&2
        return 1
      fi
      assert_contains "$temp_dir/err.txt" "$NETWORK_ERR_MSG"
      ;;

    empty-response)
      write_workspace_response "$temp_dir/workspace-response.json"
      write_usage_response_normal "$temp_dir/usage-response.json"
      run_script "$temp_dir" "empty-response"
      assert_contains "$temp_dir/out.txt" '15% used'
      ;;

    *)
      printf 'unknown scenario: %s\n' "$scenario" >&2
      return 1
      ;;
  esac

  assert_not_contains "$temp_dir/out.txt" 'test-cookie-token-xyz'
  assert_not_contains "$temp_dir/err.txt" 'test-cookie-token-xyz'
  assert_not_contains "$temp_dir/out.txt" 'env-cookie-token'
  assert_not_contains "$temp_dir/err.txt" 'env-cookie-token'
  assert_not_contains "$temp_dir/out.txt" 'bare-token-value-no-equals'
  assert_not_contains "$temp_dir/err.txt" 'bare-token-value-no-equals'

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

  printf 'PASS: %d/%d aitop-opencode scenarios\n' "$PASS_COUNT" "$TOTAL_COUNT"
}

main "$@"
