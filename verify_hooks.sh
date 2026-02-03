#!/bin/bash
# verify_hooks.sh - Diagnostic script to validate ccmetrics hooks installation

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS_COUNT=0
FAIL_COUNT=0

print_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

print_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

print_section() {
    echo ""
    echo -e "${YELLOW}=== $1 ===${NC}"
}

# 1. Prerequisites
print_section "Prerequisites"

for cmd in jq curl awk; do
    if command -v "$cmd" &> /dev/null; then
        print_pass "$cmd is installed"
    else
        print_fail "$cmd is not installed"
    fi
done

# 2. File Existence & Permissions
print_section "File Existence & Permissions"

check_hook_file() {
    local file="$1"
    local name="$2"

    if [[ ! -f "$file" ]]; then
        print_fail "$name does not exist at $file"
        return 1
    fi

    if [[ ! -x "$file" ]]; then
        print_fail "$name exists but is not executable"
        return 1
    fi

    print_pass "$name exists and is executable"
    return 0
}

check_hook_file ~/.claude/hooks/ccmetrics_statusline.sh "ccmetrics_statusline.sh"
check_hook_file ~/.claude/hooks/send_claude_metrics.sh "send_claude_metrics.sh"
check_hook_file ~/.claude/hooks/process_metrics_queue.sh "process_metrics_queue.sh"

# 3. Syntax Validation
print_section "Syntax Validation"

check_syntax() {
    local file="$1"
    local name="$2"

    if [[ ! -f "$file" ]]; then
        print_fail "$name syntax check skipped (file not found)"
        return 1
    fi

    if bash -n "$file" 2>/dev/null; then
        print_pass "$name has valid bash syntax"
    else
        print_fail "$name has syntax errors"
    fi
}

check_syntax ~/.claude/hooks/ccmetrics_statusline.sh "ccmetrics_statusline.sh"
check_syntax ~/.claude/hooks/send_claude_metrics.sh "send_claude_metrics.sh"
check_syntax ~/.claude/hooks/process_metrics_queue.sh "process_metrics_queue.sh"

# 4. Configuration Validation
print_section "Configuration Validation"

CONFIG_FILE=~/.claude/.ccmetrics-config.json

if [[ ! -f "$CONFIG_FILE" ]]; then
    print_fail "Config file does not exist at $CONFIG_FILE"
elif [[ ! -r "$CONFIG_FILE" ]]; then
    print_fail "Config file is not readable"
else
    print_pass "Config file exists and is readable"

    # Check for required fields
    if command -v jq &> /dev/null; then
        supabase_url=$(jq -r '.supabase_url // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
        supabase_key=$(jq -r '.supabase_key // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
        developer_email=$(jq -r '.developer_email // empty' "$CONFIG_FILE" 2>/dev/null || echo "")

        if [[ -n "$supabase_url" ]]; then
            print_pass "supabase_url is present"

            if [[ "$supabase_url" =~ ^https://.*\.supabase\.co ]]; then
                print_pass "supabase_url matches expected pattern"
            else
                print_fail "supabase_url does not match https://...supabase.co pattern"
            fi
        else
            print_fail "supabase_url is missing or empty"
        fi

        if [[ -n "$supabase_key" ]]; then
            print_pass "supabase_key is present"
        else
            print_fail "supabase_key is missing or empty"
        fi

        if [[ -n "$developer_email" ]]; then
            print_pass "developer_email is present"
        else
            print_fail "developer_email is missing or empty"
        fi
    else
        print_fail "jq not available, cannot validate config contents"
    fi
fi

# 5. Settings.json Hook Registration
print_section "Settings.json Hook Registration"

SETTINGS_FILE=~/.claude/settings.json

if [[ ! -f "$SETTINGS_FILE" ]]; then
    print_fail "settings.json does not exist at $SETTINGS_FILE"
else
    print_pass "settings.json exists"

    if command -v jq &> /dev/null; then
        statusline_cmd=$(jq -r '.statusLine.command // empty' "$SETTINGS_FILE" 2>/dev/null || echo "")
        session_end=$(jq -r '.hooks.SessionEnd // empty' "$SETTINGS_FILE" 2>/dev/null || echo "")
        session_start=$(jq -r '.hooks.SessionStart // empty' "$SETTINGS_FILE" 2>/dev/null || echo "")

        if [[ "$statusline_cmd" == *"ccmetrics_statusline.sh"* ]]; then
            print_pass "statusLine.command references ccmetrics_statusline.sh"
        else
            print_fail "statusLine.command does not reference ccmetrics_statusline.sh"
        fi

        if [[ "$session_end" == *"send_claude_metrics.sh"* ]]; then
            print_pass "hooks.SessionEnd contains send_claude_metrics.sh"
        else
            print_fail "hooks.SessionEnd does not contain send_claude_metrics.sh"
        fi

        if [[ "$session_start" == *"process_metrics_queue.sh"* ]]; then
            print_pass "hooks.SessionStart contains process_metrics_queue.sh"
        else
            print_fail "hooks.SessionStart does not contain process_metrics_queue.sh"
        fi
    else
        print_fail "jq not available, cannot validate settings.json contents"
    fi
fi

# 6. Functional Test: Statusline Hook
print_section "Functional Test: Statusline Hook"

if [[ -f ~/.claude/hooks/ccmetrics_statusline.sh ]] && [[ -x ~/.claude/hooks/ccmetrics_statusline.sh ]]; then
    TEST_SESSION_ID="test-verify-$(date +%s)"

    # Create sample session JSON matching real format
    SAMPLE_JSON=$(cat <<EOF
{
  "session_id": "$TEST_SESSION_ID",
  "model": {
    "id": "claude-sonnet-4-5-20250929",
    "display_name": "Sonnet 4.5"
  },
  "cost": {
    "total_cost_usd": 1.23,
    "total_duration_ms": 720000
  },
  "context_window": {
    "total_input_tokens": 45000,
    "total_output_tokens": 12000,
    "used_percentage": 28
  },
  "workspace": {
    "project_dir": "/home/user/test"
  }
}
EOF
)

    OUTPUT=$(echo "$SAMPLE_JSON" | ~/.claude/hooks/ccmetrics_statusline.sh 2>/dev/null || echo "")

    if [[ -n "$OUTPUT" ]] && [[ "$OUTPUT" == *"Sonnet"* ]] && [[ "$OUTPUT" == *"$"* ]]; then
        print_pass "Statusline hook produces valid output format"
    else
        print_fail "Statusline hook output is invalid or empty: '$OUTPUT'"
    fi

    # Clean up test cache if created
    rm -f ~/.claude/metrics_cache/"${TEST_SESSION_ID}.json" 2>/dev/null || true
else
    print_fail "Statusline hook not available for testing"
fi

# 7. Functional Test: Supabase Connectivity
print_section "Functional Test: Supabase Connectivity"

if [[ -f "$CONFIG_FILE" ]] && command -v jq &> /dev/null && command -v curl &> /dev/null; then
    supabase_url=$(jq -r '.supabase_url // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
    supabase_key=$(jq -r '.supabase_key // empty' "$CONFIG_FILE" 2>/dev/null || echo "")
    developer_email=$(jq -r '.developer_email // empty' "$CONFIG_FILE" 2>/dev/null || echo "")

    if [[ -n "$supabase_url" ]] && [[ -n "$supabase_key" ]] && [[ -n "$developer_email" ]]; then
        TEST_TIMESTAMP=$(date +%s)
        TEST_PAYLOAD=$(cat <<EOF
{
  "session_id": "test-verify-$TEST_TIMESTAMP",
  "developer": "$developer_email",
  "hostname": "test-host",
  "project_path": "/test/path",
  "duration_minutes": 1,
  "cost_usd": 0.001,
  "input_tokens": 100,
  "output_tokens": 50,
  "message_count": 2,
  "user_message_count": 1,
  "tools_used": "Bash",
  "context_usage_percent": 5,
  "model": "test-model",
  "seven_day_utilization": null,
  "seven_day_resets_at": null,
  "five_hour_utilization": null,
  "five_hour_resets_at": null,
  "seven_day_sonnet_utilization": null,
  "seven_day_sonnet_resets_at": null,
  "claude_account_email": null
}
EOF
)

        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST \
            -H "apikey: $supabase_key" \
            -H "Authorization: Bearer $supabase_key" \
            -H "Content-Type: application/json" \
            -H "Prefer: return=minimal" \
            -d "$TEST_PAYLOAD" \
            "${supabase_url}/rest/v1/sessions" 2>/dev/null || echo "000")

        if [[ "$HTTP_CODE" == "201" ]]; then
            print_pass "Supabase connectivity test succeeded (HTTP 201)"
        else
            print_fail "Supabase connectivity test failed (HTTP $HTTP_CODE)"
        fi
    else
        print_fail "Supabase credentials incomplete, skipping connectivity test"
    fi
else
    print_fail "Prerequisites missing for Supabase connectivity test"
fi

# 8. Functional Test: Queue Processor
print_section "Functional Test: Queue Processor"

if [[ -f ~/.claude/hooks/process_metrics_queue.sh ]] && [[ -x ~/.claude/hooks/process_metrics_queue.sh ]]; then
    # Run queue processor with empty stdin and SessionStart event
    if HOOK_EVENT=SessionStart ~/.claude/hooks/process_metrics_queue.sh < /dev/null &>/dev/null; then
        print_pass "Queue processor runs without error"
    else
        print_fail "Queue processor exited with error"
    fi
else
    print_fail "Queue processor not available for testing"
fi

# 9. VS Code Extension Detection
print_section "VS Code Extension Detection"

VSCODE_EXT_DETECTED=false
for ext_dir in "$HOME/.vscode/extensions" "$HOME/.vscode-server/extensions"; do
    if [[ -d "$ext_dir" ]] && ls "$ext_dir"/anthropic.claude-code* >/dev/null 2>&1; then
        VSCODE_EXT_DETECTED=true
        print_pass "VS Code Claude Code extension detected"
        echo ""
        echo "  VS Code Compatibility Information:"
        echo "  • Native UI mode: Metrics collected ✓, statusline runs but output not displayed"
        echo "  • Statusline output written to ~/.claude/metrics_cache/_statusline.txt"
        echo "  • Terminal mode: Full feature support (set \"claudeCode.useTerminal\": true)"
        echo ""
        break
    fi
done

if [[ "$VSCODE_EXT_DETECTED" == false ]]; then
    echo "  VS Code extension not detected (CLI mode assumed)"
    echo "  All features available ✓"
fi

# Summary
print_section "Summary"
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "Total checks: $TOTAL"
echo -e "${GREEN}Passed: $PASS_COUNT${NC}"
echo -e "${RED}Failed: $FAIL_COUNT${NC}"

if [[ $FAIL_COUNT -eq 0 ]]; then
    echo ""
    echo -e "${GREEN}✓ All checks passed! ccmetrics hooks are properly configured.${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}✗ Some checks failed. Review the output above for details.${NC}"
    exit 1
fi
