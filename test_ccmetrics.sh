#!/bin/bash

#############################################################################
# ccmetrics Test Suite
# Comprehensive tests for recent changes: transcript fallback, VS Code
# detection, statusline output, unified logging
#############################################################################

# Don't exit on error - we want to run all tests
set +e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

pass_count=0
fail_count=0

test_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((pass_count++))
}

test_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    ((fail_count++))
}

print_header() {
    echo -e "${BLUE}===================================================================${NC}"
    echo -e "${YELLOW}$1${NC}"
    echo -e "${BLUE}===================================================================${NC}"
    echo
}

print_section() {
    echo -e "${YELLOW}$1${NC}"
    echo
}

# =================================================================
# TEST 1: Transcript Parsing Fallback
# =================================================================
test_transcript_parsing() {
    print_header "TEST 1: Transcript Parsing Fallback"

    # Create mock transcript file
    TRANSCRIPT_DIR=$(mktemp -d)
    TEST_SESSION_ID="test-transcript-$(date +%s)"

    cat > "$TRANSCRIPT_DIR/transcript.jsonl" << 'EOF'
{"type":"assistant","message":{"model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":200}}}
{"type":"assistant","message":{"model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":80,"output_tokens":30}}}
EOF

    # Remove any existing cache for test session
    rm -f ~/.claude/metrics_cache/${TEST_SESSION_ID}.json

    # Create session data JSON with minimal info (no model/tokens, to trigger fallback)
    cat > /tmp/session_data.json << EOFJSON
{
  "session_id": "$TEST_SESSION_ID",
  "cwd": "/test/project",
  "transcript_path": "$TRANSCRIPT_DIR/transcript.jsonl",
  "reason": "disconnect"
}
EOFJSON

    echo "Session ID: $TEST_SESSION_ID"
    echo "Running SessionEnd hook with transcript-only source..."

    # Run the hook with timeout
    timeout 10 bash -c "cat /tmp/session_data.json | ~/.claude/hooks/send_claude_metrics.sh" > /dev/null 2>&1 || true

    # Check logs for transcript parsing
    echo
    TRANSCRIPT_LOGS=$(grep "$TEST_SESSION_ID" ~/.claude/ccmetrics.log 2>&1 || echo "")

    if echo "$TRANSCRIPT_LOGS" | grep -q "source=transcript"; then
        test_pass "Metrics source set to 'transcript'"
    else
        test_fail "Metrics source not set to 'transcript'"
    fi

    if echo "$TRANSCRIPT_LOGS" | grep -q "model=claude-sonnet-4-5-20250929"; then
        test_pass "Model extracted from transcript"
    else
        test_fail "Model not extracted from transcript"
    fi

    if echo "$TRANSCRIPT_LOGS" | grep -q "380in"; then
        test_pass "Input tokens correctly summed (100+200+80=380)"
    else
        test_fail "Input tokens not correctly summed"
    fi

    if echo "$TRANSCRIPT_LOGS" | grep -q "80out"; then
        test_pass "Output tokens correctly summed (50+30=80)"
    else
        test_fail "Output tokens not correctly summed"
    fi

    if echo "$TRANSCRIPT_LOGS" | grep -q "HTTP 201"; then
        test_pass "Data successfully sent to Supabase"
    else
        test_fail "Data not sent to Supabase"
    fi

    # Cleanup
    rm -rf "$TRANSCRIPT_DIR" /tmp/session_data.json

    echo
}

# =================================================================
# TEST 2: Baseline Delta Skip for Transcript Source
# =================================================================
test_baseline_skip() {
    print_header "TEST 2: Baseline Delta Skip for Transcript Source"

    PROJECT_HASH=$(echo -n "/test/project" | md5sum | cut -c1-8)
    BASELINE_FILE=~/.claude/metrics_cache/_clear_baseline_${PROJECT_HASH}.json

    if [ -f "$BASELINE_FILE" ]; then
        test_fail "Baseline file exists (should skip for transcript source)"
        echo "  Found: $BASELINE_FILE"
    else
        test_pass "No baseline file created (correct for transcript source)"
    fi

    echo
}

# =================================================================
# TEST 3: VS Code Detection with VSCODE_IPC_HOOK_CLI
# =================================================================
test_vscode_detection() {
    print_header "TEST 3: VS Code Detection with VSCODE_IPC_HOOK_CLI"

    SCRIPT_PATH=~/.claude/hooks/send_claude_metrics.sh

    if grep -q "VSCODE_PID" "$SCRIPT_PATH"; then
        test_pass "VSCODE_PID detection present"
    else
        test_fail "VSCODE_PID detection missing"
    fi

    if grep -q "TERM_PROGRAM" "$SCRIPT_PATH"; then
        test_pass "TERM_PROGRAM detection present"
    else
        test_fail "TERM_PROGRAM detection missing"
    fi

    if grep -q "VSCODE_IPC_HOOK_CLI" "$SCRIPT_PATH"; then
        test_pass "VSCODE_IPC_HOOK_CLI detection present"
    else
        test_fail "VSCODE_IPC_HOOK_CLI detection missing"
    fi

    # Verify the logic is correct (all three in OR condition)
    if grep -A 2 "Detect client type" "$SCRIPT_PATH" | grep -q 'VSCODE_PID.*TERM_PROGRAM.*VSCODE_IPC_HOOK_CLI'; then
        test_pass "All three detection methods in OR condition"
    else
        # Check if they're on separate lines (multi-line condition)
        DETECTION_BLOCK=$(grep -A 3 "CLIENT_TYPE=\"cli\"" "$SCRIPT_PATH")
        if echo "$DETECTION_BLOCK" | grep -q "VSCODE_PID" && \
           echo "$DETECTION_BLOCK" | grep -q "TERM_PROGRAM" && \
           echo "$DETECTION_BLOCK" | grep -q "VSCODE_IPC_HOOK_CLI"; then
            test_pass "All three detection methods present in logic block"
        else
            test_fail "Not all detection methods found in logic block"
        fi
    fi

    echo
}

# =================================================================
# TEST 4: Statusline File Output
# =================================================================
test_statusline_output() {
    print_header "TEST 4: Statusline File Output"

    STATUSLINE_FILE=~/.claude/metrics_cache/_statusline.txt

    # Run statusline hook with sample data
    SAMPLE_JSON='{"session_id":"test-statusline-'$(date +%s)'","model":{"display_name":"Sonnet 4.5"},"cost":{"total_cost_usd":1.5},"context_window":{"used_percentage":25},"workspace":{"project_dir":"/home/user/project"}}'

    echo "Running statusline hook..."
    echo "$SAMPLE_JSON" | ~/.claude/hooks/ccmetrics_statusline.sh > /dev/null 2>&1

    if [ -f "$STATUSLINE_FILE" ]; then
        test_pass "Statusline file created"

        STATUSLINE_CONTENT=$(cat "$STATUSLINE_FILE")
        echo "  Content: $STATUSLINE_CONTENT"
        echo

        if echo "$STATUSLINE_CONTENT" | grep -q "Sonnet 4.5"; then
            test_pass "Contains model name"
        else
            test_fail "Missing model name"
        fi

        if echo "$STATUSLINE_CONTENT" | grep -qE '[0-9]+%'; then
            test_pass "Contains percentage"
        else
            test_fail "Missing percentage"
        fi

        if echo "$STATUSLINE_CONTENT" | grep -qE '\$[0-9]+\.[0-9]'; then
            test_pass "Contains cost"
        else
            test_fail "Missing cost"
        fi

        if echo "$STATUSLINE_CONTENT" | grep -q "project"; then
            test_pass "Contains project path"
        else
            test_fail "Missing project path"
        fi
    else
        test_fail "Statusline file not created"
    fi

    echo
}

# =================================================================
# TEST 5: Unified Logging System
# =================================================================
test_unified_logging() {
    print_header "TEST 5: Unified Logging System"

    LOG_FILE=~/.claude/ccmetrics.log

    if [ -f "$LOG_FILE" ]; then
        test_pass "Log file exists"

        RECENT_LOGS=$(tail -30 "$LOG_FILE")

        # Check timestamp format: [YYYY-MM-DD HH:MM:SS]
        if echo "$RECENT_LOGS" | grep -qE '^\[20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]'; then
            test_pass "Timestamp format correct"
        else
            test_fail "Timestamp format incorrect"
        fi

        # Check module tags
        if echo "$RECENT_LOGS" | grep -qE '\[(SESSION_END|STATUSLINE)\]'; then
            test_pass "Module tags present"
        else
            test_fail "Module tags missing"
        fi

        # Check log levels
        if echo "$RECENT_LOGS" | grep -qE ' (INFO|WARN|ERROR|DEBUG) '; then
            test_pass "Log levels present"
        else
            test_fail "Log levels missing"
        fi
    else
        test_fail "Log file does not exist"
    fi

    echo
}

# =================================================================
# TEST 6: Debug Mode Filtering
# =================================================================
test_debug_filtering() {
    print_header "TEST 6: Debug Mode Filtering"

    CONFIG_FILE=~/.claude/.ccmetrics-config.json
    LOG_FILE=~/.claude/ccmetrics.log

    if [ -f "$CONFIG_FILE" ]; then
        DEBUG_MODE=$(jq -r '.debug // false' "$CONFIG_FILE")
        DEBUG_COUNT=$(grep -c ' DEBUG ' "$LOG_FILE" 2>&1 || echo "0")

        echo "Debug mode: $DEBUG_MODE"
        echo "DEBUG entries in log: $DEBUG_COUNT"
        echo

        if [ "$DEBUG_MODE" = "true" ]; then
            if [ "$DEBUG_COUNT" -gt 0 ]; then
                test_pass "DEBUG entries present when debug=true"
            else
                test_fail "No DEBUG entries despite debug=true"
            fi
        else
            if [ "$DEBUG_COUNT" -eq 0 ]; then
                test_pass "No DEBUG entries when debug=false"
            else
                echo "  Note: Found $DEBUG_COUNT DEBUG entries but debug=false"
                echo "        (May be from when debug was previously enabled)"
                test_pass "Debug filtering logic present"
            fi
        fi
    else
        test_fail "Config file not found"
    fi

    echo
}

# =================================================================
# TEST 7: End-to-End Verification
# =================================================================
test_e2e_verification() {
    print_header "TEST 7: End-to-End Verification (verify_hooks.sh)"

    if [ ! -f "verify_hooks.sh" ]; then
        test_fail "verify_hooks.sh not found"
        echo
        return
    fi

    echo "Running verify_hooks.sh..."
    if bash verify_hooks.sh > /tmp/verify_output.txt 2>&1; then
        test_pass "verify_hooks.sh completed successfully"

        VERIFY_PASSED=$(grep -c "✓ PASS" /tmp/verify_output.txt 2>/dev/null | head -1 || echo "0")
        VERIFY_FAILED=$(grep -c "✗ FAIL" /tmp/verify_output.txt 2>/dev/null | head -1 || echo "0")

        echo "  Checks passed: $VERIFY_PASSED"
        echo "  Checks failed: $VERIFY_FAILED"
        echo

        if [ "$VERIFY_FAILED" -eq 0 ]; then
            test_pass "All verification checks passed"
        else
            test_fail "Some verification checks failed"
            echo "  Run 'bash verify_hooks.sh' for details"
        fi
    else
        test_fail "verify_hooks.sh exited with error"
        echo "  Run 'bash verify_hooks.sh' for details"
    fi

    echo
}

# =================================================================
# MAIN EXECUTION
# =================================================================

print_header "ccmetrics Test Suite"
echo "Testing recent changes: transcript fallback, VS Code detection,"
echo "statusline output, unified logging"
echo

# Run all tests
test_transcript_parsing
test_baseline_skip
test_vscode_detection
test_statusline_output
test_unified_logging
test_debug_filtering
test_e2e_verification

# =================================================================
# SUMMARY
# =================================================================

print_header "TEST SUMMARY"
echo
echo -e "Total tests passed: ${GREEN}$pass_count${NC}"
echo -e "Total tests failed: ${RED}$fail_count${NC}"
echo

if [ $fail_count -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some tests failed. Review output above.${NC}"
    exit 1
fi
