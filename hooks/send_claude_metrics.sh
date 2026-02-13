#!/bin/bash
set -euo pipefail

#############################################################################
# Claude Code Metrics Collection Hook
# Sends session metadata to Supabase with retry queue for failed attempts
#############################################################################

# ============================================================================
# CONFIGURATION
# ============================================================================

# Queue and cache configuration
QUEUE_DIR="$HOME/.claude/metrics_queue"
METRICS_CACHE_DIR="$HOME/.claude/metrics_cache"
LOG_FILE="$HOME/.claude/ccmetrics.log"
MAX_QUEUE_SIZE=100  # Maximum queued payloads before cleanup

# ============================================================================
# INITIALIZATION
# ============================================================================
mkdir -p "$QUEUE_DIR"
mkdir -p "$METRICS_CACHE_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Portable MD5 hash function (Linux + macOS + fallback)
portable_md5() {
    echo -n "$1" | md5sum 2>/dev/null | cut -c1-8 \
        || md5 -rs "$1" 2>/dev/null | cut -c1-8 \
        || echo "fallback0"
}

# Validate numeric input (defense against injection)
validate_numeric() {
    local val="${1:-0}"
    if [[ "$val" =~ ^-?[0-9]*\.?[0-9]+$ ]]; then
        echo "$val"
    else
        echo "0"
    fi
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SESSION_END] $1" >> "$LOG_FILE"
}

debug_log() {
    if [ "$DEBUG_ENABLED" = "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SESSION_END] DEBUG $1" >> "$LOG_FILE"
    fi
}

# ============================================================================
# READ CONFIGURATION
# ============================================================================

CONFIG_FILE="$HOME/.claude/.ccmetrics-config.json"

# Set defaults
DEVELOPER_EMAIL="$USER"
SUPABASE_URL=""
SUPABASE_KEY=""
DEBUG_ENABLED="false"

if [ -f "$CONFIG_FILE" ]; then
    # Read all config values
    DEVELOPER_EMAIL=$(jq -r '.developer_email // empty' "$CONFIG_FILE" 2>/dev/null)
    SUPABASE_URL=$(jq -r '.supabase_url // empty' "$CONFIG_FILE" 2>/dev/null)
    SUPABASE_KEY=$(jq -r '.supabase_key // empty' "$CONFIG_FILE" 2>/dev/null)
    DEBUG_ENABLED=$(jq -r '.debug // false' "$CONFIG_FILE" 2>/dev/null || echo "false")

    # Validate critical fields
    if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_KEY" ]; then
        log "ERROR ❌ Missing Supabase credentials in config file"
        exit 1
    fi

    # Email can fallback to $USER if missing
    if [ -z "$DEVELOPER_EMAIL" ]; then
        DEVELOPER_EMAIL="$USER"
        log "WARN  ⚠️  Failed to read email from config, using \$USER: $USER"
    fi
else
    log "ERROR ❌ Config file not found at $CONFIG_FILE"
    exit 1
fi

# Queue a failed payload for retry
queue_payload() {
    local payload="$1"
    local queue_file="${QUEUE_DIR}/$(date +%s)_$(uuidgen 2>/dev/null || echo $RANDOM).json"
    local queue_tmp="${queue_file}.tmp.$$"

    # Atomic write: write to temp file, then move
    echo "$payload" > "$queue_tmp"
    mv -f "$queue_tmp" "$queue_file"
    log "INFO  ⏳ Queued payload to $queue_file"

    # Cleanup old queue if too large
    local queue_count=$(ls -1 "$QUEUE_DIR" 2>/dev/null | wc -l)
    if [ "$queue_count" -gt "$MAX_QUEUE_SIZE" ]; then
        log "WARN  ⚠️  Queue size exceeded $MAX_QUEUE_SIZE, removing oldest entries"
        ls -1t "$QUEUE_DIR" | tail -n +$((MAX_QUEUE_SIZE + 1)) | xargs -I {} rm -f "$QUEUE_DIR/{}"
    fi
}

# Check if OAuth token is expired
# Returns: 0 if valid, 1 if expired or missing
check_token_expiry() {
    local credentials_file="$1"

    if [ ! -f "$credentials_file" ]; then
        return 1
    fi

    local expires_at=$(jq -r '.claudeAiOauth.expiresAt // empty' "$credentials_file" 2>/dev/null)
    if [ -z "$expires_at" ]; then
        return 1
    fi

    local current_time=$(date +%s)
    local expires_epoch
    if echo "$expires_at" | grep -qE '^[0-9]+$'; then
        expires_epoch=$((expires_at / 1000))
    else
        expires_epoch=$(date -d "$expires_at" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${expires_at%.*}" +%s 2>/dev/null || echo 0)
    fi

    if [ "$expires_epoch" -eq 0 ]; then
        return 1
    fi

    if [ "$current_time" -ge "$expires_epoch" ]; then
        # Token is expired - log how long ago
        local diff_seconds=$((current_time - expires_epoch))
        local diff_hours=$(awk -v sec="$(validate_numeric "$diff_seconds")" 'BEGIN {printf "%.1f", sec / 3600}')
        log "WARN  ⚠️  OAuth token expired ${diff_hours}h ago (session was idle), will use cached fallback"
        return 1
    fi

    return 0
}

# Retry-enabled OAuth API call helper
# Args: url, description
# Returns: curl output on success, empty on failure
oauth_api_call() {
    local url="$1"
    local description="$2"
    local access_token="$3"

    for attempt in 1 2; do
        local response=$(curl -s --max-time 3 -w "\n%{http_code}" \
            "$url" \
            -H "Authorization: Bearer $access_token" \
            -H "Content-Type: application/json" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "Accept: application/json" 2>/dev/null)

        local http_code=$(echo "$response" | tail -1)
        local body=$(echo "$response" | sed '$d')

        # Success
        if [ "$http_code" = "200" ]; then
            echo "$response"
            return 0
        fi

        # Auth errors won't benefit from retry
        if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
            log "WARN  ⚠️  Failed to fetch $description: HTTP $http_code (auth error, skipping retry)"
            return 1
        fi

        # Retry on other errors (only on first attempt)
        if [ "$attempt" -eq 1 ]; then
            debug_log "Retrying $description after HTTP $http_code..."
            sleep 1
        else
            log "WARN  ⚠️  Failed to fetch $description: HTTP $http_code (after retry)"
            return 1
        fi
    done

    return 1
}

# Send a single payload to Supabase
send_to_supabase() {
    local payload="$1"
    local session_id=$(echo "$payload" | jq -r '.session_id // "unknown"')

    local response=$(curl -s -w "\n%{http_code}" -X POST \
        "${SUPABASE_URL}/rest/v1/sessions" \
        -H "apikey: ${SUPABASE_KEY}" \
        -H "Authorization: Bearer ${SUPABASE_KEY}" \
        -H "Content-Type: application/json" \
        -H "Prefer: return=minimal" \
        -d "$payload" \
        --max-time 5 2>/dev/null)

    local http_code=$(echo "$response" | tail -n1)

    if [ "$http_code" = "201" ]; then
        log "INFO  ✓ Session $session_id sent successfully (HTTP 201)"
        return 0
    else
        log "ERROR ✗ Failed to send session $session_id (HTTP $http_code)"
        return 1
    fi
}

# Process all queued payloads
process_queue() {
    local queue_files=$(ls -1 "$QUEUE_DIR" 2>/dev/null | grep -v '\.processing\.' | head -n 10)

    if [ -z "$queue_files" ]; then
        return 0
    fi

    log "INFO  📤 Processing $(echo "$queue_files" | wc -l) queued payloads"

    while IFS= read -r file; do
        local queue_file="${QUEUE_DIR}/${file}"
        local processing_file="${QUEUE_DIR}/${file}.processing.$$"

        # Atomic claim: rename file before processing (prevents race conditions)
        if ! mv -n "$queue_file" "$processing_file" 2>/dev/null; then
            continue  # Another process claimed it or file doesn't exist
        fi

        local payload=$(cat "$processing_file")

        # Send payload and capture HTTP response
        local response=$(curl -s -w "\n%{http_code}" -X POST \
            "${SUPABASE_URL}/rest/v1/sessions" \
            -H "apikey: ${SUPABASE_KEY}" \
            -H "Authorization: Bearer ${SUPABASE_KEY}" \
            -H "Content-Type: application/json" \
            -H "Prefer: return=minimal" \
            -d "$payload" \
            --max-time 5 2>&1)

        local http_code=$(echo "$response" | tail -n1)
        local session_id=$(echo "$payload" | jq -r '.session_id // "unknown"')

        if [ "$http_code" = "201" ]; then
            # Success - remove file
            rm -f "$processing_file"
            log "INFO  ✓ Removed $file from queue (HTTP 201)"
        elif [[ "$http_code" =~ ^4[0-9]{2}$ ]]; then
            # Client error (4xx) - malformed payload, delete it
            rm -f "$processing_file"
            log "ERROR ✗ Removed corrupted file $file from queue (HTTP $http_code - client error)"
        else
            # Server error (5xx) or other - keep for retry
            mv -f "$processing_file" "$queue_file"
            log "WARN  ⏳ Keeping $file in queue (HTTP $http_code - server error, will retry)"
            break  # Stop processing more files on server errors
        fi

        sleep 0.5
    done <<< "$queue_files"
}

# ============================================================================
# MAIN LOGIC
# ============================================================================

# Check if this is a SessionStart hook call (for processing queue)
if [ "${HOOK_EVENT:-}" = "SessionStart" ]; then
    log "INFO  🔄 SessionStart detected, processing queue"
    # Clean up stale cache files older than 30 days
    find "$METRICS_CACHE_DIR" -name "*.json" -mtime +30 -delete 2>/dev/null || true
    # Clean up legacy per-session OAuth files (migrated to _oauth_cache.json)
    find "$METRICS_CACHE_DIR" -name "*_oauth.json" ! -name "_oauth_cache.json" -delete 2>/dev/null || true
    process_queue
    exit 0
fi

# Extract session data from stdin
SESSION_DATA=$(cat)
debug_log "raw stdin: $SESSION_DATA"

# Validate we have session data
if [ -z "$SESSION_DATA" ] || [ "$SESSION_DATA" = "{}" ]; then
    log "WARN  ⚠️  No session data received, skipping"
    exit 0
fi

# ============================================================================
# EXTRACT SESSION INFO FROM STDIN
# ============================================================================

SESSION_ID=$(echo "$SESSION_DATA" | jq -r '.session_id // "unknown"')
PROJECT_DIR=$(echo "$SESSION_DATA" | jq -r '.cwd // "unknown"')
TRANSCRIPT_PATH=$(echo "$SESSION_DATA" | jq -r '.transcript_path // ""')
REASON=$(echo "$SESSION_DATA" | jq -r '.reason // ""')

# ============================================================================
# DETECT /clear EVENTS
# ============================================================================
# When /clear is executed, SessionEnd runs with reason="clear"
# We log it and continue to normal processing (baseline delta handles it)

if [ "$REASON" = "clear" ]; then
    debug_log "CLEAR EVENT DETECTED: reason=$REASON (will use baseline delta)"
    log "INFO  🔄 CLEAR detected for session $SESSION_ID (project_hash=$(portable_md5 "$PROJECT_DIR"))"
fi

# ============================================================================
# EXTRACTION HELPER WITH FALLBACK
# ============================================================================

# Extract metrics from JSON with error handling and defaults
# Args: json_data, field_path, default_value
extract_metric() {
    local data="$1"
    local field="$2"
    local default="${3:-}"

    echo "$data" | jq -r "$field // empty" 2>/dev/null || echo "$default"
}


# ============================================================================
# READ CACHED METRICS FROM STATUSLINE HOOK
# ============================================================================

CACHE_FILE="${METRICS_CACHE_DIR}/${SESSION_ID}.json"
METRICS_SOURCE="none"

# Try cache first
if [ -f "$CACHE_FILE" ]; then
    log "INFO  📂 Reading cached metrics for session $SESSION_ID"
    CACHED_DATA=$(cat "$CACHE_FILE")

    # Validate cache structure before using (check non-empty and has .model field)
    if [ -n "$CACHED_DATA" ] && echo "$CACHED_DATA" | jq -e '.model | select(. != null)' >/dev/null 2>&1; then
        METRICS_SOURCE="cache"
        debug_log "cache valid, context_window: $(echo "$CACHED_DATA" | jq -c '.context_window // {}' 2>/dev/null)"

        # Extract pre-calculated values from cache (set by statusline hook)
        MODEL=$(extract_metric "$CACHED_DATA" '.model.display_name // .model.id' 'unknown')
        TOTAL_COST=$(extract_metric "$CACHED_DATA" '.cost.total_cost_usd' '0')
        DURATION_MS=$(extract_metric "$CACHED_DATA" '.cost.total_duration_ms' '0')
        INPUT_TOKENS=$(extract_metric "$CACHED_DATA" '.context_window.total_input_tokens' '0')
        OUTPUT_TOKENS=$(extract_metric "$CACHED_DATA" '.context_window.total_output_tokens' '0')
        CONTEXT_PERCENT=$(extract_metric "$CACHED_DATA" '.context_window.used_percentage' '0')
        debug_log "extracted from cache: model=$MODEL cost=$TOTAL_COST duration_ms=$DURATION_MS in=$INPUT_TOKENS out=$OUTPUT_TOKENS context_pct=$CONTEXT_PERCENT"
    else
        log "WARN  ⚠️  Cache file invalid/empty for session $SESSION_ID, trying stdin fallback"
        CACHED_DATA=""
    fi

    # Clean up cache file after reading
    rm -f "$CACHE_FILE"
fi

# Fallback to stdin if cache failed or didn't exist
if [ "$METRICS_SOURCE" = "none" ]; then
    log "INFO  📂 Extracting metrics from stdin (cache unavailable)"
    METRICS_SOURCE="stdin"

    MODEL=$(extract_metric "$SESSION_DATA" '.model.display_name // .model.id' 'unknown')
    TOTAL_COST=$(extract_metric "$SESSION_DATA" '.cost.total_cost_usd' '0')
    DURATION_MS=$(extract_metric "$SESSION_DATA" '.cost.total_duration_ms' '0')
    INPUT_TOKENS=$(extract_metric "$SESSION_DATA" '.context_window.total_input_tokens' '0')
    OUTPUT_TOKENS=$(extract_metric "$SESSION_DATA" '.context_window.total_output_tokens' '0')
    CONTEXT_PERCENT=$(extract_metric "$SESSION_DATA" '.context_window.used_percentage' '0')
    debug_log "extracted from stdin: model=$MODEL cost=$TOTAL_COST duration_ms=$DURATION_MS in=$INPUT_TOKENS out=$OUTPUT_TOKENS context_pct=$CONTEXT_PERCENT"
fi

# ============================================================================
# TRANSCRIPT PARSING FALLBACK (defense-in-depth for VS Code native UI edge cases)
# ============================================================================
# If both cache and stdin produced no meaningful data, parse the transcript JSONL
# directly. This covers edge cases where the statusline hook didn't fire.

if { [ -z "$MODEL" ] || [ "$MODEL" = "unknown" ]; } && [ "${INPUT_TOKENS:-0}" = "0" ] && [ "${OUTPUT_TOKENS:-0}" = "0" ]; then
    if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
        log "INFO  📄 Parsing transcript for metrics (cache and stdin both empty)"
        METRICS_SOURCE="transcript"

        # Extract model from first assistant message
        T_MODEL=$(jq -r 'select(.type == "assistant") | .message.model // empty' "$TRANSCRIPT_PATH" 2>/dev/null | head -1)
        [ -n "$T_MODEL" ] && MODEL="$T_MODEL"

        # Sum tokens across all assistant messages
        # input_tokens is non-cached only; add cache tokens for total input
        T_INPUT=$(jq -r 'select(.type == "assistant" and .message.usage) | .message.usage | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))' "$TRANSCRIPT_PATH" 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
        T_OUTPUT=$(jq -r 'select(.type == "assistant" and .message.usage) | .message.usage.output_tokens // 0' "$TRANSCRIPT_PATH" 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
        [ "${T_INPUT:-0}" -gt 0 ] 2>/dev/null && INPUT_TOKENS="$T_INPUT"
        [ "${T_OUTPUT:-0}" -gt 0 ] 2>/dev/null && OUTPUT_TOKENS="$T_OUTPUT"

        debug_log "extracted from transcript: model=$MODEL in=$INPUT_TOKENS out=$OUTPUT_TOKENS"
    fi
fi

# Calculate approximate cost, context, and duration when using transcript source
if [ "$METRICS_SOURCE" = "transcript" ]; then
    # --- Cost Calculation ---
    # Pricing per 1M tokens (Jan 2025 - https://www.anthropic.com/pricing)
    # Opus 4: $15 input, $75 output
    # Sonnet 4: $3 input, $15 output
    # Note: Approximate - doesn't account for cache pricing tiers
    if [[ "$MODEL" == *"opus"* ]]; then
        TOTAL_COST=$(awk -v inp="$(validate_numeric "${INPUT_TOKENS:-0}")" -v out="$(validate_numeric "${OUTPUT_TOKENS:-0}")" \
            'BEGIN {printf "%.4f", (inp * 15 + out * 75) / 1000000}')
    else
        # Default to Sonnet pricing for unknown models
        TOTAL_COST=$(awk -v inp="$(validate_numeric "${INPUT_TOKENS:-0}")" -v out="$(validate_numeric "${OUTPUT_TOKENS:-0}")" \
            'BEGIN {printf "%.4f", (inp * 3 + out * 15) / 1000000}')
    fi

    # --- Context Usage Calculation ---
    # Context window is 200000 for Claude models
    CONTEXT_WINDOW_SIZE=200000
    TOTAL_TOKENS=$((${INPUT_TOKENS:-0} + ${OUTPUT_TOKENS:-0}))
    CONTEXT_PERCENT=$(awk -v total="$(validate_numeric "$TOTAL_TOKENS")" -v window="$CONTEXT_WINDOW_SIZE" \
        'BEGIN {printf "%.0f", (total * 100) / window}')

    # --- Duration Calculation ---
    # Extract first and last timestamps from transcript
    FIRST_TS=$(jq -r 'select(.timestamp) | .timestamp' "$TRANSCRIPT_PATH" 2>/dev/null | head -1)
    LAST_TS=$(jq -r 'select(.timestamp) | .timestamp' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1)
    if [ -n "$FIRST_TS" ] && [ -n "$LAST_TS" ]; then
        # Convert ISO timestamps to epoch seconds and calculate difference (Linux + macOS)
        FIRST_EPOCH=$(date -d "$FIRST_TS" +%s 2>/dev/null \
            || date -jf "%Y-%m-%dT%H:%M:%S" "${FIRST_TS%.*}" +%s 2>/dev/null \
            || echo 0)
        LAST_EPOCH=$(date -d "$LAST_TS" +%s 2>/dev/null \
            || date -jf "%Y-%m-%dT%H:%M:%S" "${LAST_TS%.*}" +%s 2>/dev/null \
            || echo 0)
        if [ "$FIRST_EPOCH" -gt 0 ] && [ "$LAST_EPOCH" -gt 0 ]; then
            DURATION_MS=$(( (LAST_EPOCH - FIRST_EPOCH) * 1000 ))
        fi
    fi

    debug_log "calculated from transcript: cost=\$${TOTAL_COST}, context=${CONTEXT_PERCENT}%, duration=${DURATION_MS}ms"
fi

# Detect client type (CLI vs VS Code)
CLIENT_TYPE="cli"
if [ -n "${VSCODE_PID:-}" ] || [ "${TERM_PROGRAM:-}" = "vscode" ] \
   || [ -n "${VSCODE_IPC_HOOK_CLI:-}" ]; then
    CLIENT_TYPE="vscode"
fi

# ============================================================================
# BASELINE DELTA COMPUTATION FOR /clear HANDLING
# ============================================================================
# Transcript source: tokens are already per-session (transcript resets after
# /clear), so baseline delta logic does not apply.

# Compute project hash for baseline file scoping
PROJECT_HASH=$(portable_md5 "$PROJECT_DIR")
BASELINE_FILE="${METRICS_CACHE_DIR}/_clear_baseline_${PROJECT_HASH}.json"

# Store original cumulative values (needed for baseline save on /clear)
CUMULATIVE_COST="$TOTAL_COST"
CUMULATIVE_DURATION_MS="$DURATION_MS"
CUMULATIVE_INPUT="$INPUT_TOKENS"
CUMULATIVE_OUTPUT="$OUTPUT_TOKENS"

if [ "$METRICS_SOURCE" = "transcript" ]; then
    debug_log "Skipping baseline delta (transcript source: values are already per-session)"
else
    # If baseline exists, compute delta (per-session values)
    if [ -f "$BASELINE_FILE" ]; then
        debug_log "Baseline file found: $BASELINE_FILE"
        BASELINE_DATA=$(cat "$BASELINE_FILE")

        BASELINE_COST=$(echo "$BASELINE_DATA" | jq -r '.cost_usd // 0')
        BASELINE_DURATION_MS=$(echo "$BASELINE_DATA" | jq -r '.duration_ms // 0')
        BASELINE_INPUT=$(echo "$BASELINE_DATA" | jq -r '.input_tokens // 0')
        BASELINE_OUTPUT=$(echo "$BASELINE_DATA" | jq -r '.output_tokens // 0')

        debug_log "Baseline values: cost=$BASELINE_COST duration_ms=$BASELINE_DURATION_MS in=$BASELINE_INPUT out=$BASELINE_OUTPUT"
        debug_log "Cumulative values: cost=$CUMULATIVE_COST duration_ms=$CUMULATIVE_DURATION_MS in=$CUMULATIVE_INPUT out=$CUMULATIVE_OUTPUT"

        # Edge case: if baseline > current, treat as stale (Claude Code restarted)
        if [ "$(awk -v bc="$(validate_numeric "$BASELINE_COST")" -v cc="$(validate_numeric "$CUMULATIVE_COST")" \
                    -v bi="$(validate_numeric "$BASELINE_INPUT")" -v ci="$(validate_numeric "$CUMULATIVE_INPUT")" \
                    'BEGIN {print (bc > cc || bi > ci) ? 1 : 0}')" -eq 1 ]; then
            log "WARN  ⚠️  Stale baseline detected (baseline > current), treating as first session"
            debug_log "Deleting stale baseline file: $BASELINE_FILE"
            rm -f "$BASELINE_FILE"
        else
            # Compute deltas
            TOTAL_COST=$(awk -v cum="$(validate_numeric "$CUMULATIVE_COST")" -v base="$(validate_numeric "$BASELINE_COST")" \
                'BEGIN {printf "%.2f", cum - base}')
            DURATION_MS=$(awk -v cum="$(validate_numeric "$CUMULATIVE_DURATION_MS")" -v base="$(validate_numeric "$BASELINE_DURATION_MS")" \
                'BEGIN {printf "%.0f", cum - base}')
            INPUT_TOKENS=$(awk -v cum="$(validate_numeric "$CUMULATIVE_INPUT")" -v base="$(validate_numeric "$BASELINE_INPUT")" \
                'BEGIN {printf "%.0f", cum - base}')
            OUTPUT_TOKENS=$(awk -v cum="$(validate_numeric "$CUMULATIVE_OUTPUT")" -v base="$(validate_numeric "$BASELINE_OUTPUT")" \
                'BEGIN {printf "%.0f", cum - base}')

            log "INFO  📊 Delta computed: cost=\$$TOTAL_COST (cumulative=\$$CUMULATIVE_COST - baseline=\$$BASELINE_COST), duration=${DURATION_MS}ms, tokens=${INPUT_TOKENS}in+${OUTPUT_TOKENS}out"
            debug_log "Delta values: cost=$TOTAL_COST duration_ms=$DURATION_MS in=$INPUT_TOKENS out=$OUTPUT_TOKENS"
        fi
    else
        debug_log "No baseline file found, using cumulative values as delta (first session)"
    fi
fi

# Calculate duration in minutes (from potentially delta-adjusted DURATION_MS)
DURATION_MIN=$(awk -v ms="$(validate_numeric "$DURATION_MS")" 'BEGIN {printf "%.2f", ms / 60000}' 2>/dev/null || echo "0")

# ============================================================================
# BASELINE MANAGEMENT (must happen before send/skip to avoid double-counting)
# ============================================================================
# Skip for transcript source: no cumulative values to baseline against

if [ "$METRICS_SOURCE" != "transcript" ]; then
    if [ "$REASON" = "clear" ]; then
        # Save current cumulative values as baseline for next session
        BASELINE_TMP="${BASELINE_FILE}.tmp.$$"
        jq -n \
          --arg cost "$CUMULATIVE_COST" \
          --arg duration "$CUMULATIVE_DURATION_MS" \
          --arg input "$CUMULATIVE_INPUT" \
          --arg output "$CUMULATIVE_OUTPUT" \
          --argjson saved_at "$(date +%s)" \
          '{
            cost_usd: ($cost | tonumber),
            duration_ms: ($duration | tonumber),
            input_tokens: ($input | tonumber),
            output_tokens: ($output | tonumber),
            saved_at: $saved_at
          }' > "$BASELINE_TMP"
        if [ -s "$BASELINE_TMP" ] && mv -f "$BASELINE_TMP" "$BASELINE_FILE" 2>/dev/null; then
            log "INFO  💾 Saved baseline for next session: cost=\$$CUMULATIVE_COST, tokens=${CUMULATIVE_INPUT}in+${CUMULATIVE_OUTPUT}out"
        else
            log "ERROR ❌ Failed to save baseline file: $BASELINE_FILE"
            rm -f "$BASELINE_TMP"
        fi
        debug_log "Baseline saved to: $BASELINE_FILE"
    fi
fi

# Always clean up baseline on normal exit (outside the metrics source check)
if [ "$REASON" != "clear" ] && [ -f "$BASELINE_FILE" ]; then
    rm -f "$BASELINE_FILE"
    log "INFO  🗑️  Deleted baseline file (session chain ended)"
    debug_log "Baseline file removed: $BASELINE_FILE"
fi

# ============================================================================
# COUNT MESSAGES AND TOOLS FROM TRANSCRIPT
# ============================================================================

MSG_COUNT=0
USER_MSG_COUNT=0
TOOLS=""

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    MSG_COUNT=$(jq -s '[.[] | select(.type == "user" or .type == "assistant")] | length' "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)
    USER_MSG_COUNT=$(jq -s '[.[] | select(.type == "user")] | length' "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)
    # Tools are nested inside assistant message content
    TOOLS=$(jq -rs '[.[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | .name] | unique | join(", ")' "$TRANSCRIPT_PATH" 2>/dev/null || echo "")
fi

# ============================================================================
# FETCH USAGE LIMITS
# ============================================================================

SEVEN_DAY_UTIL="null"
SEVEN_DAY_RESETS="null"
FIVE_HOUR_UTIL="null"
FIVE_HOUR_RESETS="null"
SEVEN_DAY_SONNET_UTIL="null"
SEVEN_DAY_SONNET_RESETS="null"
CLAUDE_ACCOUNT_EMAIL=""

CREDENTIALS_FILE="$HOME/.claude/.credentials.json"
if [ -f "$CREDENTIALS_FILE" ]; then
    # Check token expiry first
    if check_token_expiry "$CREDENTIALS_FILE"; then
        ACCESS_TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null)
        if [ -n "$ACCESS_TOKEN" ]; then
            # Fetch usage data with retry
            USAGE_RAW=$(oauth_api_call "https://api.anthropic.com/api/oauth/usage" "usage data" "$ACCESS_TOKEN")
            if [ -n "$USAGE_RAW" ]; then
                USAGE_HTTP_CODE=$(echo "$USAGE_RAW" | tail -1)
                USAGE_RESPONSE=$(echo "$USAGE_RAW" | sed '$d')

                if [ -n "$USAGE_RESPONSE" ] && ! echo "$USAGE_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
                    SEVEN_DAY_UTIL=$(echo "$USAGE_RESPONSE" | jq -r '.seven_day.utilization // "null"')
                    SEVEN_DAY_RESETS=$(echo "$USAGE_RESPONSE" | jq -r '.seven_day.resets_at // "null"')
                    FIVE_HOUR_UTIL=$(echo "$USAGE_RESPONSE" | jq -r '.five_hour.utilization // "null"')
                    FIVE_HOUR_RESETS=$(echo "$USAGE_RESPONSE" | jq -r '.five_hour.resets_at // "null"')
                    SEVEN_DAY_SONNET_UTIL=$(echo "$USAGE_RESPONSE" | jq -r '.seven_day_sonnet.utilization // "null"')
                    SEVEN_DAY_SONNET_RESETS=$(echo "$USAGE_RESPONSE" | jq -r '.seven_day_sonnet.resets_at // "null"')
                    debug_log "Full usage API response: $USAGE_RESPONSE"
                    log "INFO  📈 Usage fetched: 7d=${SEVEN_DAY_UTIL}%, 5h=${FIVE_HOUR_UTIL}%, 7d_sonnet=${SEVEN_DAY_SONNET_UTIL}%"
                else
                    if echo "$USAGE_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
                        USAGE_ERR=$(echo "$USAGE_RESPONSE" | jq -r '.error.message // .error // "unknown error"')
                        log "WARN  ⚠️  Failed to fetch usage data: $USAGE_ERR (HTTP $USAGE_HTTP_CODE)"
                    fi
                fi
            fi

            # Fetch profile data with retry
            PROFILE_RAW=$(oauth_api_call "https://api.anthropic.com/api/oauth/profile" "profile data" "$ACCESS_TOKEN")
            if [ -n "$PROFILE_RAW" ]; then
                PROFILE_HTTP_CODE=$(echo "$PROFILE_RAW" | tail -1)
                PROFILE_RESPONSE=$(echo "$PROFILE_RAW" | sed '$d')

                if [ -n "$PROFILE_RESPONSE" ] && ! echo "$PROFILE_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
                    CLAUDE_ACCOUNT_EMAIL=$(echo "$PROFILE_RESPONSE" | jq -r '.account.email // ""')
                    log "INFO  👤 Claude account: ${CLAUDE_ACCOUNT_EMAIL}"
                else
                    if echo "$PROFILE_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
                        PROFILE_ERR=$(echo "$PROFILE_RESPONSE" | jq -r '.error.message // .error // "unknown error"')
                        log "WARN  ⚠️  Failed to fetch profile data: $PROFILE_ERR (HTTP $PROFILE_HTTP_CODE)"
                    fi
                fi
            fi
        fi
    fi
fi

# ============================================================================
# FALLBACK TO CACHED OAUTH DATA
# ============================================================================

# If utilization fields are still null, check for cached OAuth data from statusline
OAUTH_CACHE_FILE="${METRICS_CACHE_DIR}/_oauth_cache.json"
if [[ "$SEVEN_DAY_UTIL" == "null" || -z "$CLAUDE_ACCOUNT_EMAIL" ]] && [ -f "$OAUTH_CACHE_FILE" ]; then
    log "INFO  📂 Using cached OAuth data from statusline hook"
    CACHED_OAUTH=$(cat "$OAUTH_CACHE_FILE")

    # Calculate cache age
    CACHED_AT=$(echo "$CACHED_OAUTH" | jq -r '.fetched_at // 0')
    if [ "$CACHED_AT" -gt 0 ]; then
        CACHE_AGE_SEC=$(($(date +%s) - CACHED_AT))
        CACHE_AGE_MIN=$(awk -v sec="$(validate_numeric "$CACHE_AGE_SEC")" 'BEGIN {printf "%.1f", sec / 60}')
        log "INFO  📅 OAuth cache age: ${CACHE_AGE_MIN} minutes"
    fi

    # Use cached values if current ones are null
    if [ "$SEVEN_DAY_UTIL" == "null" ]; then
        SEVEN_DAY_UTIL=$(echo "$CACHED_OAUTH" | jq -r '.seven_day_utilization // "null"')
        SEVEN_DAY_RESETS=$(echo "$CACHED_OAUTH" | jq -r '.seven_day_resets_at // "null"')
    fi
    if [ "$FIVE_HOUR_UTIL" == "null" ]; then
        FIVE_HOUR_UTIL=$(echo "$CACHED_OAUTH" | jq -r '.five_hour_utilization // "null"')
        FIVE_HOUR_RESETS=$(echo "$CACHED_OAUTH" | jq -r '.five_hour_resets_at // "null"')
    fi
    if [ "$SEVEN_DAY_SONNET_UTIL" == "null" ]; then
        SEVEN_DAY_SONNET_UTIL=$(echo "$CACHED_OAUTH" | jq -r '.seven_day_sonnet_utilization // "null"')
        SEVEN_DAY_SONNET_RESETS=$(echo "$CACHED_OAUTH" | jq -r '.seven_day_sonnet_resets_at // "null"')
    fi
    if [ -z "$CLAUDE_ACCOUNT_EMAIL" ]; then
        CLAUDE_ACCOUNT_EMAIL=$(echo "$CACHED_OAUTH" | jq -r '.claude_account_email // ""')
    fi
fi


# ============================================================================
# CREATE PAYLOAD
# ============================================================================

# Defense-in-depth: apply defaults to prevent crashes from empty strings
MODEL="${MODEL:-unknown}"
TOTAL_COST="${TOTAL_COST:-0}"
DURATION_MS="${DURATION_MS:-0}"
INPUT_TOKENS="${INPUT_TOKENS:-0}"
OUTPUT_TOKENS="${OUTPUT_TOKENS:-0}"
CONTEXT_PERCENT="${CONTEXT_PERCENT:-0}"
MSG_COUNT="${MSG_COUNT:-0}"
USER_MSG_COUNT="${USER_MSG_COUNT:-0}"
TOOLS="${TOOLS:-}"
SEVEN_DAY_UTIL="${SEVEN_DAY_UTIL:-null}"
SEVEN_DAY_RESETS="${SEVEN_DAY_RESETS:-null}"
FIVE_HOUR_UTIL="${FIVE_HOUR_UTIL:-null}"
FIVE_HOUR_RESETS="${FIVE_HOUR_RESETS:-null}"
SEVEN_DAY_SONNET_UTIL="${SEVEN_DAY_SONNET_UTIL:-null}"
SEVEN_DAY_SONNET_RESETS="${SEVEN_DAY_SONNET_RESETS:-null}"
CLAUDE_ACCOUNT_EMAIL="${CLAUDE_ACCOUNT_EMAIL:-}"

# Format cost to 2 decimal places (validate first)
TOTAL_COST=$(validate_numeric "$TOTAL_COST")
TOTAL_COST=$(printf "%.2f" "$TOTAL_COST")

# Build payload
PAYLOAD=$(jq -n \
  --arg session_id "$SESSION_ID" \
  --arg developer "$DEVELOPER_EMAIL" \
  --arg hostname "${HOSTNAME:-$(hostname 2>/dev/null || echo 'unknown')}" \
  --arg project "$PROJECT_DIR" \
  --arg duration "$DURATION_MIN" \
  --arg cost "$TOTAL_COST" \
  --arg input "$INPUT_TOKENS" \
  --arg output "$OUTPUT_TOKENS" \
  --arg messages "$MSG_COUNT" \
  --arg user_messages "$USER_MSG_COUNT" \
  --arg tools "$TOOLS" \
  --arg context_percent "$CONTEXT_PERCENT" \
  --arg model "$MODEL" \
  --argjson seven_day_util "$SEVEN_DAY_UTIL" \
  --arg seven_day_resets "$SEVEN_DAY_RESETS" \
  --argjson five_hour_util "$FIVE_HOUR_UTIL" \
  --arg five_hour_resets "$FIVE_HOUR_RESETS" \
  --argjson seven_day_sonnet_util "$SEVEN_DAY_SONNET_UTIL" \
  --arg seven_day_sonnet_resets "$SEVEN_DAY_SONNET_RESETS" \
  --arg claude_account "$CLAUDE_ACCOUNT_EMAIL" \
  --arg metrics_source "$METRICS_SOURCE" \
  --arg client_type "$CLIENT_TYPE" \
  '{
    session_id: $session_id,
    developer: $developer,
    hostname: $hostname,
    project_path: $project,
    duration_minutes: ($duration | tonumber),
    cost_usd: ($cost | tonumber),
    input_tokens: ($input | tonumber),
    output_tokens: ($output | tonumber),
    message_count: ($messages | tonumber),
    user_message_count: ($user_messages | tonumber),
    tools_used: $tools,
    context_usage_percent: ($context_percent | tonumber),
    model: $model,
    seven_day_utilization: (if $seven_day_util == null then null else ($seven_day_util | floor) end),
    seven_day_resets_at: (if $seven_day_resets == "null" then null else $seven_day_resets end),
    five_hour_utilization: (if $five_hour_util == null then null else ($five_hour_util | floor) end),
    five_hour_resets_at: (if $five_hour_resets == "null" then null else $five_hour_resets end),
    seven_day_sonnet_utilization: (if $seven_day_sonnet_util == null then null else ($seven_day_sonnet_util | floor) end),
    seven_day_sonnet_resets_at: (if $seven_day_sonnet_resets == "null" then null else $seven_day_sonnet_resets end),
    claude_account_email: (if $claude_account == "" then null else $claude_account end),
    metrics_source: $metrics_source,
    client_type: $client_type
  }')

# ============================================================================
# SKIP EMPTY PAYLOADS
# ============================================================================

# Skip if no meaningful metrics (no tokens, no cost, unknown model)
if [[ "$INPUT_TOKENS" -eq 0 && "$OUTPUT_TOKENS" -eq 0 && "$MODEL" == "unknown" ]]; then
    if [ "$(awk -v cost="$(validate_numeric "$TOTAL_COST")" 'BEGIN {print (cost == 0) ? 1 : 0}')" -eq 1 ]; then
        log "INFO  ⏭️  Skipping empty payload for session $SESSION_ID (source=$METRICS_SOURCE) - no meaningful metrics (0 tokens, \$0 cost, unknown model)"
        exit 0
    fi
fi

# ============================================================================
# SEND TO SUPABASE (WITH QUEUE ON FAILURE)
# ============================================================================

log "INFO  📊 Processing session $SESSION_ID (model=$MODEL, source=$METRICS_SOURCE, reason=${REASON:-normal}, client=$CLIENT_TYPE, cost=\$$TOTAL_COST, tokens=${INPUT_TOKENS}in+${OUTPUT_TOKENS}out)"
debug_log "📤 Full payload: $PAYLOAD"

if send_to_supabase "$PAYLOAD"; then
    process_queue
else
    queue_payload "$PAYLOAD"
fi

exit 0
