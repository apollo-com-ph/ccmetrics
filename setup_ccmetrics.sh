#!/bin/bash

#############################################################################
# Claude Code Metrics Setup Script
# 
# Quick install:
#   curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/ccmetrics/main/setup_ccmetrics.sh | bash
#
# Or download first:
#   curl -O https://raw.githubusercontent.com/apollo-com-ph/ccmetrics/main/setup_ccmetrics.sh
#   bash setup_ccmetrics.sh
#############################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REPO_URL="https://raw.githubusercontent.com/apollo-com-ph/ccmetrics/main"
CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
QUEUE_DIR="$CLAUDE_DIR/metrics_queue"
LOG_FILE="$CLAUDE_DIR/ccmetrics.log"

# CLI flags
DRY_RUN=false
UNINSTALL=false

#############################################################################
# HELPER FUNCTIONS
#############################################################################

print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Claude Code Metrics Collection Setup${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() {
    echo -e "${GREEN}▶${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# Prompt before overwriting a config field
# Args: field_name, current_value, mask (optional, if "true" shows [existing] instead of value)
# Returns: 0 + echoes old value if user says N (keep), 1 if user says Y (overwrite)
prompt_overwrite_field() {
    local field_name="$1"
    local current_value="$2"
    local mask="${3:-false}"

    # Display current value (masked if needed)
    local display_value="$current_value"
    if [ "$mask" = "true" ]; then
        display_value="[existing]"
    fi

    echo -e "  ${field_name}: ${display_value}" >&2
    read -p "  Overwrite? (y/N): " -n 1 -r >&2
    echo >&2

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 1  # User wants to overwrite
    else
        return 0  # User wants to keep
    fi
}

# Show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dry-run     Show what would be changed without modifying files"
    echo "  --uninstall   Remove ccmetrics hooks from settings.json"
    echo "  -h, --help    Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                  # Normal installation"
    echo "  $0 --dry-run        # Preview changes to settings.json"
    echo "  $0 --uninstall      # Remove ccmetrics configuration"
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --uninstall)
                UNINSTALL=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Detect OS
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            OS=$ID
            OS_VERSION=$VERSION_ID
        else
            OS="linux"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
    elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        OS="windows"
    else
        OS="unknown"
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if running as root (don't want this)
check_not_root() {
    if [ "$EUID" -eq 0 ]; then
        print_error "Please do not run this script as root or with sudo"
        print_info "Run as your regular user: bash setup_ccmetrics.sh"
        exit 1
    fi
}

#############################################################################
# DEPENDENCY CHECKING
#############################################################################

print_install_instructions() {
    echo ""
    print_info "Install missing dependencies:"
    echo ""
    echo "  macOS:        brew install jq curl"
    echo "  Ubuntu/Debian: sudo apt install jq curl"
    echo "  Fedora/RHEL:  sudo dnf install jq curl"
    echo "  Arch:         sudo pacman -S jq curl"
    echo ""
    print_info "Note: awk and curl are pre-installed on most Unix systems."
    echo ""
}

check_dependencies() {
    print_step "Checking dependencies..."

    local missing_deps=()

    # Check jq
    if ! command_exists jq; then
        print_warning "jq not found"
        missing_deps+=("jq")
    else
        print_success "jq found: $(jq --version)"
    fi

    # Check curl
    if ! command_exists curl; then
        print_warning "curl not found"
        missing_deps+=("curl")
    else
        print_success "curl found"
    fi

    # Check awk (used for floating-point math)
    if ! command_exists awk; then
        print_warning "awk not found"
        missing_deps+=("awk")
    else
        print_success "awk found"
    fi

    # Exit with helpful message if any dependencies are missing
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo ""
        print_error "Missing dependencies: ${missing_deps[*]}"
        print_install_instructions
        exit 1
    fi

    echo ""
}

#############################################################################
# CONFIGURATION COLLECTION
#############################################################################

collect_config() {
    print_step "Configuration Setup"
    echo ""

    # Load existing config as defaults if available
    local config_file="$CLAUDE_DIR/.ccmetrics-config.json"
    local EXISTING_EMAIL=""
    local EXISTING_URL=""
    local EXISTING_KEY=""
    local EXISTING_DEBUG=""

    if [ -f "$config_file" ]; then
        print_info "Found existing configuration."
        EXISTING_EMAIL=$(jq -r '.developer_email // empty' "$config_file" 2>/dev/null)
        EXISTING_URL=$(jq -r '.supabase_url // empty' "$config_file" 2>/dev/null)
        EXISTING_KEY=$(jq -r '.supabase_key // empty' "$config_file" 2>/dev/null)
        EXISTING_DEBUG=$(jq -r '.debug // false' "$config_file" 2>/dev/null)
        echo ""
    fi

    # Work Email - prompt for overwrite if existing value present
    if [ -n "$EXISTING_EMAIL" ]; then
        if prompt_overwrite_field "developer_email" "$EXISTING_EMAIL" false; then
            WORK_EMAIL="$EXISTING_EMAIL"
        else
            # User wants to overwrite, prompt for new value
            read -p "Enter your work email: " WORK_EMAIL
            if [[ ! $WORK_EMAIL =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                print_warning "Email format may be invalid, but continuing..."
            fi
        fi
    else
        # Fresh install - use original prompt
        local default_email="${USER}@${HOSTNAME}"
        read -p "Enter your work email (default: $default_email): " WORK_EMAIL
        WORK_EMAIL=${WORK_EMAIL:-$default_email}
        if [[ ! $WORK_EMAIL =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            print_warning "Email format may be invalid, but continuing..."
        fi
    fi
    echo ""

    # Supabase URL - prompt for overwrite if existing value present
    if [ -n "$EXISTING_URL" ]; then
        if prompt_overwrite_field "supabase_url" "$EXISTING_URL" false; then
            SUPABASE_URL="$EXISTING_URL"
        else
            # User wants to overwrite, prompt for new value with validation
            while true; do
                read -p "Enter your Supabase Project URL (e.g., https://xxxxx.supabase.co): " SUPABASE_URL
                if [[ $SUPABASE_URL =~ ^https://.*\.supabase\.co$ ]]; then
                    break
                else
                    print_error "Invalid Supabase URL format. Should be: https://xxxxx.supabase.co"
                fi
            done
        fi
    else
        # Fresh install - use original prompt with validation
        while true; do
            read -p "Enter your Supabase Project URL (e.g., https://xxxxx.supabase.co): " SUPABASE_URL
            if [[ $SUPABASE_URL =~ ^https://.*\.supabase\.co$ ]]; then
                break
            else
                print_error "Invalid Supabase URL format. Should be: https://xxxxx.supabase.co"
            fi
        done
    fi
    echo ""

    # Supabase API Key - prompt for overwrite if existing value present (masked)
    if [ -n "$EXISTING_KEY" ]; then
        if prompt_overwrite_field "supabase_key" "$EXISTING_KEY" true; then
            SUPABASE_KEY="$EXISTING_KEY"
        else
            # User wants to overwrite, prompt for new value with validation
            while true; do
                read -p "Enter your Supabase publishable key (starts with sb_publishable_): " SUPABASE_KEY
                if [ -n "$SUPABASE_KEY" ]; then
                    if [[ ! $SUPABASE_KEY =~ ^sb_publishable_ ]]; then
                        print_warning "Key doesn't start with 'sb_publishable_'. Legacy anon keys are deprecated."
                        read -p "Continue anyway? (y/n) " -n 1 -r
                        echo
                        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                            print_info "Get your publishable key from: Supabase Dashboard > Project Settings > API"
                            exit 1
                        fi
                    fi
                    break
                else
                    print_error "API key cannot be empty"
                fi
            done
        fi
    else
        # Fresh install - use original prompt with validation
        while true; do
            read -p "Enter your Supabase publishable key (starts with sb_publishable_): " SUPABASE_KEY
            if [ -n "$SUPABASE_KEY" ]; then
                if [[ ! $SUPABASE_KEY =~ ^sb_publishable_ ]]; then
                    print_warning "Key doesn't start with 'sb_publishable_'. Legacy anon keys are deprecated."
                    read -p "Continue anyway? (y/n) " -n 1 -r
                    echo
                    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                        print_info "Get your publishable key from: Supabase Dashboard > Project Settings > API"
                        exit 1
                    fi
                fi
                break
            else
                print_error "API key cannot be empty"
            fi
        done
    fi
    echo ""

    # Debug - only prompt if existing value is true (default is false, so no point prompting when already false)
    if [ "$EXISTING_DEBUG" = "true" ]; then
        if prompt_overwrite_field "debug" "true" false; then
            DEBUG_VALUE="true"
        else
            DEBUG_VALUE="false"
        fi
        echo ""
    else
        # No existing config or debug is already false
        DEBUG_VALUE="false"
    fi

    print_success "Configuration collected"
}

#############################################################################
# FILE CREATION
#############################################################################

create_directories() {
    print_step "Creating directories..."

    mkdir -p "$CLAUDE_DIR"
    mkdir -p "$HOOKS_DIR"
    mkdir -p "$QUEUE_DIR"
    touch "$LOG_FILE"

    print_success "Directories created"
}

create_config_file() {
    print_step "Creating configuration file..."

    local config_file="$CLAUDE_DIR/.ccmetrics-config.json"

    # Create config with jq for proper JSON formatting
    jq -n \
        --arg email "$WORK_EMAIL" \
        --arg url "$SUPABASE_URL" \
        --arg key "$SUPABASE_KEY" \
        --argjson debug "$DEBUG_VALUE" \
        '{
            developer_email: $email,
            supabase_url: $url,
            supabase_key: $key,
            created_at: (now | todate),
            debug: $debug
        }' > "$config_file"

    # Secure the file (only user can read/write)
    chmod 600 "$config_file"

    print_success "Configuration file created at $config_file"
}

download_or_create_hook_script() {
    print_step "Installing metrics hook script..."
    
    local hook_file="$HOOKS_DIR/send_claude_metrics.sh"
    
    # Create embedded version
    print_info "Creating hook script (repo not available)"
        
    cat > "$hook_file" << 'HOOKEOF'
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

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# ============================================================================
# READ CONFIGURATION
# ============================================================================

CONFIG_FILE="$HOME/.claude/.ccmetrics-config.json"

# Set defaults
DEVELOPER_EMAIL="$USER"
SUPABASE_URL=""
SUPABASE_KEY=""

if [ -f "$CONFIG_FILE" ]; then
    # Read all config values
    DEVELOPER_EMAIL=$(jq -r '.developer_email // empty' "$CONFIG_FILE" 2>/dev/null)
    SUPABASE_URL=$(jq -r '.supabase_url // empty' "$CONFIG_FILE" 2>/dev/null)
    SUPABASE_KEY=$(jq -r '.supabase_key // empty' "$CONFIG_FILE" 2>/dev/null)
    DEBUG_ENABLED=$(jq -r '.debug // false' "$CONFIG_FILE" 2>/dev/null || echo "false")

    # Validate critical fields
    if [ -z "$SUPABASE_URL" ] || [ -z "$SUPABASE_KEY" ]; then
        log "❌ ERROR: Missing Supabase credentials in config file"
        exit 1
    fi

    # Email can fallback to $USER if missing
    if [ -z "$DEVELOPER_EMAIL" ]; then
        DEVELOPER_EMAIL="$USER"
        log "⚠️  Failed to read email from config, using \$USER: $USER"
    fi
else
    log "❌ ERROR: Config file not found at $CONFIG_FILE"
    exit 1
fi

# Debug logging support
DEBUG_LOG="$HOME/.claude/ccmetrics_debug.log"
debug_log() {
    if [ "$DEBUG_ENABLED" = "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SESSION_END] $1" >> "$DEBUG_LOG"
    fi
}

# Queue a failed payload for retry
queue_payload() {
    local payload="$1"
    local queue_file="${QUEUE_DIR}/$(date +%s)_$(uuidgen 2>/dev/null || echo $RANDOM).json"

    echo "$payload" > "$queue_file"
    log "⏳ Queued payload to: $queue_file"

    # Cleanup old queue if too large
    local queue_count=$(ls -1 "$QUEUE_DIR" 2>/dev/null | wc -l)
    if [ "$queue_count" -gt "$MAX_QUEUE_SIZE" ]; then
        log "⚠️  Queue size exceeded $MAX_QUEUE_SIZE, removing oldest entries"
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
        local diff_hours=$(awk "BEGIN {printf \"%.1f\", $diff_seconds / 3600}")
        log "⚠️  OAuth token expired ${diff_hours}h ago (session was idle). Usage/profile data will use cached fallback."
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
            log "⚠️  Failed to fetch $description: HTTP $http_code (auth error, skipping retry)"
            return 1
        fi

        # Retry on other errors (only on first attempt)
        if [ "$attempt" -eq 1 ]; then
            debug_log "Retrying $description after HTTP $http_code..."
            sleep 1
        else
            log "⚠️  Failed to fetch $description: HTTP $http_code (after retry)"
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
        --max-time 5 2>&1)
    
    local http_code=$(echo "$response" | tail -n1)
    
    if [ "$http_code" = "201" ]; then
        log "✓ Session $session_id sent successfully (HTTP 201)"
        return 0
    else
        log "✗ Failed to send session $session_id (HTTP $http_code)"
        return 1
    fi
}

# Process all queued payloads
process_queue() {
    local queue_files=$(ls -1 "$QUEUE_DIR" 2>/dev/null | head -n 10)
    
    if [ -z "$queue_files" ]; then
        return 0
    fi
    
    log "📤 Processing $(echo "$queue_files" | wc -l) queued payloads..."
    
    while IFS= read -r file; do
        local queue_file="${QUEUE_DIR}/${file}"
        
        if [ ! -f "$queue_file" ]; then
            continue
        fi
        
        local payload=$(cat "$queue_file")
        
        if send_to_supabase "$payload"; then
            rm -f "$queue_file"
            log "✓ Removed $file from queue"
        else
            log "⏳ Keeping $file in queue for next retry"
            break
        fi
        
        sleep 0.5
    done <<< "$queue_files"
}

# ============================================================================
# MAIN LOGIC
# ============================================================================

# Check if this is a SessionStart hook call (for processing queue)
if [ "${HOOK_EVENT:-}" = "SessionStart" ]; then
    log "🔄 SessionStart detected - processing queue"
    # Clean up stale cache files older than 30 days
    find "$METRICS_CACHE_DIR" -name "*.json" -mtime +30 -delete 2>/dev/null || true
    process_queue
    exit 0
fi

# Extract session data from stdin
SESSION_DATA=$(cat)
debug_log "raw stdin: $SESSION_DATA"

# Validate we have session data
if [ -z "$SESSION_DATA" ] || [ "$SESSION_DATA" = "{}" ]; then
    log "⚠️  No session data received, skipping"
    exit 0
fi

# ============================================================================
# EXTRACT SESSION INFO FROM STDIN
# ============================================================================

SESSION_ID=$(echo "$SESSION_DATA" | jq -r '.session_id // "unknown"')
PROJECT_DIR=$(echo "$SESSION_DATA" | jq -r '.cwd // "unknown"')
TRANSCRIPT_PATH=$(echo "$SESSION_DATA" | jq -r '.transcript_path // ""')

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
    log "📂 Reading cached metrics for session $SESSION_ID"
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
        log "⚠️  Cache file invalid/empty for session $SESSION_ID, trying stdin fallback"
        CACHED_DATA=""
    fi

    # Clean up cache file after reading
    rm -f "$CACHE_FILE"
fi

# Fallback to stdin if cache failed or didn't exist
if [ "$METRICS_SOURCE" = "none" ]; then
    log "📂 Extracting metrics from stdin (cache unavailable)"
    METRICS_SOURCE="stdin"

    MODEL=$(extract_metric "$SESSION_DATA" '.model.display_name // .model.id' 'unknown')
    TOTAL_COST=$(extract_metric "$SESSION_DATA" '.cost.total_cost_usd' '0')
    DURATION_MS=$(extract_metric "$SESSION_DATA" '.cost.total_duration_ms' '0')
    INPUT_TOKENS=$(extract_metric "$SESSION_DATA" '.context_window.total_input_tokens' '0')
    OUTPUT_TOKENS=$(extract_metric "$SESSION_DATA" '.context_window.total_output_tokens' '0')
    CONTEXT_PERCENT=$(extract_metric "$SESSION_DATA" '.context_window.used_percentage' '0')
    debug_log "extracted from stdin: model=$MODEL cost=$TOTAL_COST duration_ms=$DURATION_MS in=$INPUT_TOKENS out=$OUTPUT_TOKENS context_pct=$CONTEXT_PERCENT"
fi

# Calculate duration in minutes
DURATION_MIN=$(awk "BEGIN {printf \"%.2f\", $DURATION_MS / 60000}" 2>/dev/null || echo "0")

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
                    log "📈 Usage fetched: 7-day utilization ${SEVEN_DAY_UTIL}%"
                else
                    if echo "$USAGE_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
                        USAGE_ERR=$(echo "$USAGE_RESPONSE" | jq -r '.error.message // .error // "unknown error"')
                        log "⚠️  Failed to fetch usage data: $USAGE_ERR (HTTP $USAGE_HTTP_CODE)"
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
                    log "👤 Claude account: ${CLAUDE_ACCOUNT_EMAIL}"
                else
                    if echo "$PROFILE_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
                        PROFILE_ERR=$(echo "$PROFILE_RESPONSE" | jq -r '.error.message // .error // "unknown error"')
                        log "⚠️  Failed to fetch profile data: $PROFILE_ERR (HTTP $PROFILE_HTTP_CODE)"
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
OAUTH_CACHE_FILE="${METRICS_CACHE_DIR}/${SESSION_ID}_oauth.json"
if [[ "$SEVEN_DAY_UTIL" == "null" || -z "$CLAUDE_ACCOUNT_EMAIL" ]] && [ -f "$OAUTH_CACHE_FILE" ]; then
    log "📂 Using cached OAuth data from statusline hook"
    CACHED_OAUTH=$(cat "$OAUTH_CACHE_FILE")

    # Calculate cache age
    CACHED_AT=$(echo "$CACHED_OAUTH" | jq -r '.fetched_at // 0')
    if [ "$CACHED_AT" -gt 0 ]; then
        CACHE_AGE_SEC=$(($(date +%s) - CACHED_AT))
        CACHE_AGE_MIN=$(awk "BEGIN {printf \"%.1f\", $CACHE_AGE_SEC / 60}")
        log "📅 Cache age: ${CACHE_AGE_MIN} minutes"
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

    # Clean up cache file
    rm -f "$OAUTH_CACHE_FILE"
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

# Format cost to 2 decimal places
TOTAL_COST=$(printf "%.2f" "$TOTAL_COST")

PAYLOAD=$(jq -n \
  --arg session_id "$SESSION_ID" \
  --arg developer "$DEVELOPER_EMAIL" \
  --arg hostname "$HOSTNAME" \
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
    claude_account_email: (if $claude_account == "" then null else $claude_account end)
  }')
debug_log "payload context_usage_percent=$(echo "$PAYLOAD" | jq -r '.context_usage_percent' 2>/dev/null)"

# ============================================================================
# SKIP EMPTY PAYLOADS
# ============================================================================

# Skip if no meaningful metrics (no tokens, no cost, unknown model)
if [[ "$INPUT_TOKENS" -eq 0 && "$OUTPUT_TOKENS" -eq 0 && "$MODEL" == "unknown" ]]; then
    if [ "$(awk "BEGIN {print ($TOTAL_COST == 0) ? 1 : 0}")" -eq 1 ]; then
        log "⏭️  Skipping empty payload for session $SESSION_ID (source: $METRICS_SOURCE) - no meaningful metrics (0 tokens, \$0 cost, unknown model)"
        # Clean up OAuth cache if it exists
        OAUTH_CACHE_FILE="${METRICS_CACHE_DIR}/${SESSION_ID}_oauth.json"
        rm -f "$OAUTH_CACHE_FILE"
        exit 0
    fi
fi

# ============================================================================
# SEND TO SUPABASE (WITH QUEUE ON FAILURE)
# ============================================================================

log "📊 Processing session: $SESSION_ID"
log "📤 Payload: $PAYLOAD"

if send_to_supabase "$PAYLOAD"; then
    process_queue
else
    queue_payload "$PAYLOAD"
fi

exit 0
HOOKEOF

    chmod +x "$hook_file"
    print_success "Hook script installed and configured"
}

create_queue_processor() {
    print_step "Installing queue processor..."

    local processor_file="$HOOKS_DIR/process_metrics_queue.sh"

    cat > "$processor_file" << 'QUEUEEOF'
#!/bin/bash
set -euo pipefail

# This hook runs on SessionStart to retry failed metrics
export HOOK_EVENT="SessionStart"

# Call the main metrics script to process queue
~/.claude/hooks/send_claude_metrics.sh < /dev/null

exit 0
QUEUEEOF

    chmod +x "$processor_file"
    print_success "Queue processor installed"
}

create_statusline_script() {
    print_step "Installing custom statusline script..."

    local statusline_file="$HOOKS_DIR/ccmetrics_statusline.sh"

    cat > "$statusline_file" << 'STATUSEOF'
#!/bin/bash
set -euo pipefail

#############################################################################
# Custom Claude Code Statusline - Comprehensive Session Metrics
# Shows: [Model]%/min/$usd/inK/outK/totK /path
#############################################################################

# Cache directory for metrics (shared with SessionEnd hook)
METRICS_CACHE_DIR="$HOME/.claude/metrics_cache"
mkdir -p "$METRICS_CACHE_DIR"

# Read session data from stdin
INPUT=$(cat)

# Debug mode support
DEBUG_ENABLED=false
CONFIG_FILE="$HOME/.claude/.ccmetrics-config.json"
if [ -f "$CONFIG_FILE" ]; then
    DEBUG_ENABLED=$(jq -r '.debug // false' "$CONFIG_FILE" 2>/dev/null || echo "false")
fi
DEBUG_LOG="$HOME/.claude/ccmetrics_debug.log"
debug_log() {
    if [ "$DEBUG_ENABLED" = "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STATUSLINE] $1" >> "$DEBUG_LOG"
    fi
}
debug_log "raw stdin: $INPUT"

# Cache session data for SessionEnd hook to read (high-watermark for used_percentage)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
if [ -n "$SESSION_ID" ]; then
    CACHE_FILE="${METRICS_CACHE_DIR}/${SESSION_ID}.json"
    INCOMING_PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0')
    debug_log "session=$SESSION_ID incoming_pct=$INCOMING_PCT"

    if [ -f "$CACHE_FILE" ]; then
        OLD_PCT=$(jq -r '.context_window.used_percentage // 0' "$CACHE_FILE" 2>/dev/null || echo "0")
        debug_log "old_pct=$OLD_PCT"

        # Only apply high-watermark when incoming is zero; non-zero values always overwrite
        CACHE_TMP="${CACHE_FILE}.tmp.$$"
        if [ "$(awk "BEGIN {print ($INCOMING_PCT == 0) ? 1 : 0}")" -eq 1 ]; then
            debug_log "HIGH-WATERMARK: incoming is 0, keeping old=$OLD_PCT"
            echo "$INPUT" | jq --argjson old_pct "$OLD_PCT" '.context_window.used_percentage = $old_pct' > "$CACHE_TMP"
            if [ -s "$CACHE_TMP" ]; then
                mv -f "$CACHE_TMP" "$CACHE_FILE"
            else
                rm -f "$CACHE_TMP"
            fi
        else
            debug_log "writing incoming=$INCOMING_PCT (non-zero, overwriting old=$OLD_PCT)"
            echo "$INPUT" > "$CACHE_TMP" && mv -f "$CACHE_TMP" "$CACHE_FILE"
        fi
    else
        debug_log "no existing cache, writing incoming=$INCOMING_PCT"
        CACHE_TMP="${CACHE_FILE}.tmp.$$"
        echo "$INPUT" > "$CACHE_TMP" && mv -f "$CACHE_TMP" "$CACHE_FILE"
    fi
fi

# ============================================================================
# BACKGROUND OAUTH DATA CACHING (runs async, doesn't block statusline output)
# ============================================================================

# Run OAuth fetch in background - does not block statusline output
(
    # Only fetch every 5 minutes
    OAUTH_CACHE_FILE="${METRICS_CACHE_DIR}/${SESSION_ID}_oauth.json"
    LAST_FETCH=0
    if [ -f "$OAUTH_CACHE_FILE" ]; then
        LAST_FETCH=$(jq -r '.fetched_at // 0' "$OAUTH_CACHE_FILE" 2>/dev/null || echo "0")
    fi

    CURRENT_TIME=$(date +%s)
    TIME_SINCE_FETCH=$((CURRENT_TIME - LAST_FETCH))

    # Only fetch if > 5 minutes since last fetch
    if [ "$TIME_SINCE_FETCH" -lt 300 ]; then
        exit 0
    fi

    # Check token expiry
    CREDENTIALS_FILE="$HOME/.claude/.credentials.json"
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        exit 0
    fi

    EXPIRES_AT=$(jq -r '.claudeAiOauth.expiresAt // empty' "$CREDENTIALS_FILE" 2>/dev/null)
    if [ -z "$EXPIRES_AT" ]; then
        exit 0
    fi

    if echo "$EXPIRES_AT" | grep -qE '^[0-9]+$'; then
        EXPIRES_EPOCH=$((EXPIRES_AT / 1000))
    else
        EXPIRES_EPOCH=$(date -d "$EXPIRES_AT" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${EXPIRES_AT%.*}" +%s 2>/dev/null || echo 0)
    fi
    if [ "$EXPIRES_EPOCH" -eq 0 ] || [ "$CURRENT_TIME" -ge "$EXPIRES_EPOCH" ]; then
        exit 0
    fi

    # Token is valid, fetch OAuth data
    ACCESS_TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null)
    if [ -z "$ACCESS_TOKEN" ]; then
        exit 0
    fi

    # Fetch usage (2s timeout)
    USAGE_RAW=$(curl -s --max-time 2 -w "\n%{http_code}" \
        "https://api.anthropic.com/api/oauth/usage" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Accept: application/json" 2>/dev/null)
    USAGE_HTTP_CODE=$(echo "$USAGE_RAW" | tail -1)
    USAGE_RESPONSE=$(echo "$USAGE_RAW" | sed '$d')

    SEVEN_DAY_UTIL="null"
    SEVEN_DAY_RESETS="null"
    FIVE_HOUR_UTIL="null"
    FIVE_HOUR_RESETS="null"
    SEVEN_DAY_SONNET_UTIL="null"
    SEVEN_DAY_SONNET_RESETS="null"

    if [ "$USAGE_HTTP_CODE" = "200" ] && [ -n "$USAGE_RESPONSE" ]; then
        SEVEN_DAY_UTIL=$(echo "$USAGE_RESPONSE" | jq -r '.seven_day.utilization // "null"')
        SEVEN_DAY_RESETS=$(echo "$USAGE_RESPONSE" | jq -r '.seven_day.resets_at // "null"')
        FIVE_HOUR_UTIL=$(echo "$USAGE_RESPONSE" | jq -r '.five_hour.utilization // "null"')
        FIVE_HOUR_RESETS=$(echo "$USAGE_RESPONSE" | jq -r '.five_hour.resets_at // "null"')
        SEVEN_DAY_SONNET_UTIL=$(echo "$USAGE_RESPONSE" | jq -r '.seven_day_sonnet.utilization // "null"')
        SEVEN_DAY_SONNET_RESETS=$(echo "$USAGE_RESPONSE" | jq -r '.seven_day_sonnet.resets_at // "null"')
    fi

    # Fetch profile (2s timeout)
    PROFILE_RAW=$(curl -s --max-time 2 -w "\n%{http_code}" \
        "https://api.anthropic.com/api/oauth/profile" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Accept: application/json" 2>/dev/null)
    PROFILE_HTTP_CODE=$(echo "$PROFILE_RAW" | tail -1)
    PROFILE_RESPONSE=$(echo "$PROFILE_RAW" | sed '$d')

    CLAUDE_ACCOUNT_EMAIL=""
    if [ "$PROFILE_HTTP_CODE" = "200" ] && [ -n "$PROFILE_RESPONSE" ]; then
        CLAUDE_ACCOUNT_EMAIL=$(echo "$PROFILE_RESPONSE" | jq -r '.account.email // ""')
    fi

    # Write cache atomically
    OAUTH_CACHE_TMP="${OAUTH_CACHE_FILE}.tmp.$$"
    jq -n \
        --argjson fetched_at "$CURRENT_TIME" \
        --argjson seven_day_util "$SEVEN_DAY_UTIL" \
        --arg seven_day_resets "$SEVEN_DAY_RESETS" \
        --argjson five_hour_util "$FIVE_HOUR_UTIL" \
        --arg five_hour_resets "$FIVE_HOUR_RESETS" \
        --argjson seven_day_sonnet_util "$SEVEN_DAY_SONNET_UTIL" \
        --arg seven_day_sonnet_resets "$SEVEN_DAY_SONNET_RESETS" \
        --arg claude_account "$CLAUDE_ACCOUNT_EMAIL" \
        '{
            fetched_at: $fetched_at,
            seven_day_utilization: $seven_day_util,
            seven_day_resets_at: (if $seven_day_resets == "null" then null else $seven_day_resets end),
            five_hour_utilization: $five_hour_util,
            five_hour_resets_at: (if $five_hour_resets == "null" then null else $five_hour_resets end),
            seven_day_sonnet_utilization: $seven_day_sonnet_util,
            seven_day_sonnet_resets_at: (if $seven_day_sonnet_resets == "null" then null else $seven_day_sonnet_resets end),
            claude_account_email: (if $claude_account == "" then null else $claude_account end)
        }' > "$OAUTH_CACHE_TMP" 2>/dev/null
    if [ -s "$OAUTH_CACHE_TMP" ]; then
        mv -f "$OAUTH_CACHE_TMP" "$OAUTH_CACHE_FILE"
    else
        rm -f "$OAUTH_CACHE_TMP"
    fi
) &

# Extract data using jq
MODEL=$(echo "$INPUT" | jq -r '.model.display_name // .model.id // "Unknown"')
INPUT_TOKENS=$(echo "$INPUT" | jq -r '.context_window.total_input_tokens // 0')
OUTPUT_TOKENS=$(echo "$INPUT" | jq -r '.context_window.total_output_tokens // 0')
USED_PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0')
DURATION_MS=$(echo "$INPUT" | jq -r '.cost.total_duration_ms // 0')
COST_USD=$(echo "$INPUT" | jq -r '.cost.total_cost_usd // 0')
PROJECT_DIR=$(echo "$INPUT" | jq -r '.workspace.project_dir // ""')

# Calculate total tokens
TOTAL_TOKENS=$((INPUT_TOKENS + OUTPUT_TOKENS))

# Format model name: 10 chars, right padded with spaces
format_model() {
    local model="$1"
    printf "%-10.10s" "$model"
}

# Format percentage: 2 chars + "%", left padded with 0, whole numbers
format_percentage() {
    local pct="$1"
    local rounded=$(awk "BEGIN {printf \"%.0f\", $pct + 0.5}")
    printf "%02d%%" "$rounded"
}

# Format duration: 4 chars, minutes, left padded with 0
format_duration() {
    local ms="$1"
    local minutes=$(awk "BEGIN {printf \"%.0f\", ($ms + 30000) / 60000}")
    printf "%04d" "$minutes"
}

# Format cost: 4 chars, $0.0 to $999, right padded
format_cost() {
    local cost="$1"

    # Handle zero or very small values
    if [ "$(awk "BEGIN {print ($cost < 0.05) ? 1 : 0}")" -eq 1 ]; then
        echo "\$0.0"
        return
    fi

    # $0.1-$0.9: "$0.X" (1 decimal)
    if [ "$(awk "BEGIN {print ($cost < 1.0) ? 1 : 0}")" -eq 1 ]; then
        local tenths=$(awk "BEGIN {printf \"%.0f\", $cost * 10}")
        printf "\$0.%s" "$tenths"
        return
    fi

    # $1.0-$9.9: "$X.X" (1 decimal)
    if [ "$(awk "BEGIN {print ($cost < 10.0) ? 1 : 0}")" -eq 1 ]; then
        printf "\$%.1f" "$cost"
        return
    fi

    # $10-$99: "$XX " (space padded right)
    if [ "$(awk "BEGIN {print ($cost < 100.0) ? 1 : 0}")" -eq 1 ]; then
        printf "\$%2.0f " "$cost"
        return
    fi

    # $100-$999: "$XXX"
    printf "\$%3.0f" "$cost"
}

# Format tokens: 4 chars, 0.0K to 999K
format_tokens() {
    local tokens=$1

    # 0-999: "   X" (right aligned, no K)
    if [ "$tokens" -lt 1000 ]; then
        printf "%4d" "$tokens"
        return
    fi

    # 1000-9999: "X.XK" (1 decimal)
    if [ "$tokens" -lt 10000 ]; then
        local k_value=$(awk "BEGIN {printf \"%.1f\", $tokens / 1000}")
        printf "%sK" "$k_value"
        return
    fi

    # 10000-99999: " XXK" (space padded)
    if [ "$tokens" -lt 100000 ]; then
        local k_int=$(awk "BEGIN {printf \"%.0f\", $tokens / 1000}")
        printf "%3dK" "$k_int"
        return
    fi

    # 100000-999999: "XXXK"
    local k_int=$(awk "BEGIN {printf \"%.0f\", $tokens / 1000}")
    printf "%3dK" "$k_int"
}

# Format project directory: truncate from left if too long
format_project_dir() {
    local path="$1"

    # Default if missing
    if [ -z "$path" ]; then
        echo ""
        return
    fi

    # Get terminal width
    local term_width=$(tput cols 2>/dev/null || echo 80)

    # Fixed width of format: 40 chars
    local fixed_width=40
    local path_max=$((term_width - fixed_width - 1))

    # If terminal too narrow, omit path
    if [ "$path_max" -lt 10 ]; then
        echo ""
        return
    fi

    # Truncate from left if needed
    if [ ${#path} -gt $path_max ]; then
        echo "...${path: -$((path_max - 3))}"
    else
        echo "$path"
    fi
}

# Apply formatting
MODEL_FMT=$(format_model "$MODEL")
PCT_FMT=$(format_percentage "$USED_PCT")
DUR_FMT=$(format_duration "$DURATION_MS")
COST_FMT=$(format_cost "$COST_USD")
INPUT_FMT=$(format_tokens $INPUT_TOKENS)
OUTPUT_FMT=$(format_tokens $OUTPUT_TOKENS)
TOTAL_FMT=$(format_tokens $TOTAL_TOKENS)
PROJECT_FMT=$(format_project_dir "$PROJECT_DIR")

# Output statusline: [Model]%/min/$usd/inK/outK/totK /path
echo "[${MODEL_FMT}]${PCT_FMT}/${DUR_FMT}/${COST_FMT}/${INPUT_FMT}/${OUTPUT_FMT}/${TOTAL_FMT} ${PROJECT_FMT}"

exit 0
STATUSEOF

    chmod +x "$statusline_file"
    print_success "Custom statusline script installed"
}

# ccmetrics hook definitions (used for install/uninstall)
get_ccmetrics_config() {
    cat << 'EOF'
{
  "model": "opusplan",
  "permissions": {
    "defaultMode": "plan"
  },
  "statusLine": {
    "type": "command",
    "command": "~/.claude/hooks/ccmetrics_statusline.sh"
  },
  "hooks": {
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/send_claude_metrics.sh",
            "timeout": 20
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/process_metrics_queue.sh",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
EOF
}

# Check if ccmetrics hooks are already installed
has_ccmetrics_hooks() {
    local settings_file="$1"
    [ -f "$settings_file" ] || return 1

    # Check for our specific hook commands
    jq -e '.hooks.SessionEnd[]?.hooks[]? | select(.command | contains("send_claude_metrics"))' "$settings_file" >/dev/null 2>&1 ||
    jq -e '.hooks.SessionStart[]?.hooks[]? | select(.command | contains("process_metrics_queue"))' "$settings_file" >/dev/null 2>&1 ||
    jq -e '.statusLine.command | contains("ccmetrics_statusline")' "$settings_file" >/dev/null 2>&1
}

# Remove ccmetrics hooks from settings, preserving everything else
remove_ccmetrics_hooks() {
    local settings_file="$1"

    jq '
    # Remove ccmetrics from SessionEnd hooks
    if .hooks.SessionEnd then
        .hooks.SessionEnd = [.hooks.SessionEnd[] | select(
            (.hooks // []) | all(.command | contains("send_claude_metrics") | not)
        )]
    else . end |

    # Remove ccmetrics from SessionStart hooks
    if .hooks.SessionStart then
        .hooks.SessionStart = [.hooks.SessionStart[] | select(
            (.hooks // []) | all(.command | contains("process_metrics_queue") | not)
        )]
    else . end |

    # Clean up empty hook arrays
    if .hooks.SessionEnd == [] then del(.hooks.SessionEnd) else . end |
    if .hooks.SessionStart == [] then del(.hooks.SessionStart) else . end |
    if .hooks == {} then del(.hooks) else . end |

    # Remove ccmetrics statusLine if present
    if .statusLine.command and (.statusLine.command | contains("ccmetrics_statusline")) then
        del(.statusLine)
    else . end
    ' "$settings_file"
}

# Merge ccmetrics config into existing settings
merge_ccmetrics_config() {
    local settings_file="$1"
    local target_model="$2"
    local target_mode="$3"
    local ccmetrics_config
    ccmetrics_config=$(get_ccmetrics_config)

    if [ -f "$settings_file" ]; then
        # First remove any existing ccmetrics hooks to avoid duplicates
        local cleaned
        cleaned=$(remove_ccmetrics_hooks "$settings_file")

        # Deep merge: existing settings + ccmetrics config
        # For hooks arrays, we append rather than replace
        echo "$cleaned" | jq --argjson cc "$ccmetrics_config" --arg model "$target_model" --arg mode "$target_mode" '
        # Set model to target value
        .model = $model |

        # Set permissions.defaultMode to target value (preserves existing allow/deny)
        .permissions = (.permissions // {}) |
        .permissions.defaultMode = $mode |

        # Set statusLine (ccmetrics takes precedence)
        .statusLine = $cc.statusLine |

        # Initialize hooks if not present
        .hooks = (.hooks // {}) |

        # Append SessionEnd hooks
        .hooks.SessionEnd = ((.hooks.SessionEnd // []) + $cc.hooks.SessionEnd) |

        # Append SessionStart hooks
        .hooks.SessionStart = ((.hooks.SessionStart // []) + $cc.hooks.SessionStart)
        '
    else
        # No existing settings, use target values with ccmetrics hooks
        echo "$ccmetrics_config" | jq --arg model "$target_model" --arg mode "$target_mode" '
        .model = $model |
        .permissions.defaultMode = $mode
        '
    fi
}

# Show diff between current and proposed settings
show_settings_diff() {
    local settings_file="$1"
    local new_settings="$2"

    if [ -f "$settings_file" ]; then
        print_info "Changes to $settings_file:"
        echo ""
        # Use diff, show context
        diff -u "$settings_file" <(echo "$new_settings") || true
        echo ""
    else
        print_info "New file will be created: $settings_file"
        echo ""
        echo "$new_settings" | jq .
        echo ""
    fi
}

configure_claude_settings() {
    print_step "Configuring Claude Code settings..."

    local settings_file="$CLAUDE_DIR/settings.json"
    local backup_file="$CLAUDE_DIR/settings.json.backup.$(date +%s)"

    # Inform if already installed (merge is safe, always proceed)
    if has_ccmetrics_hooks "$settings_file"; then
        print_info "ccmetrics hooks already installed, updating..."
    fi

    # Determine target model and defaultMode values (with prompting if existing file differs)
    local new_model="opusplan"
    local new_default_mode="plan"

    # Only prompt when NOT in dry-run mode and settings file exists
    if [ "$DRY_RUN" != true ] && [ -f "$settings_file" ]; then
        local existing_model=$(jq -r '.model // empty' "$settings_file" 2>/dev/null)
        local existing_mode=$(jq -r '.permissions.defaultMode // empty' "$settings_file" 2>/dev/null)

        # Only prompt for model if existing value differs from ccmetrics default
        if [ -n "$existing_model" ] && [ "$existing_model" != "opusplan" ]; then
            echo ""
            echo -e "  model: ${existing_model} → opusplan" >&2
            read -p "  Overwrite? (y/N): " -n 1 -r >&2
            echo >&2
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                new_model="$existing_model"
            fi
        fi

        # Only prompt for defaultMode if existing value differs from ccmetrics default
        if [ -n "$existing_mode" ] && [ "$existing_mode" != "plan" ]; then
            echo -e "  permissions.defaultMode: ${existing_mode} → plan" >&2
            read -p "  Overwrite? (y/N): " -n 1 -r >&2
            echo >&2
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                new_default_mode="$existing_mode"
            fi
            echo ""
        fi
    fi

    # Generate merged configuration
    local new_settings
    new_settings=$(merge_ccmetrics_config "$settings_file" "$new_model" "$new_default_mode")

    # Validate JSON before proceeding
    if ! echo "$new_settings" | jq empty 2>/dev/null; then
        print_error "Failed to generate valid JSON configuration"
        print_error "This is a bug - please report it"
        return 1
    fi

    # Dry run: show diff and exit
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY RUN] Would make the following changes:"
        show_settings_diff "$settings_file" "$new_settings"
        print_info "[DRY RUN] No files were modified"
        return 0
    fi

    # Backup existing settings
    if [ -f "$settings_file" ]; then
        print_info "Backing up existing settings to: $backup_file"
        cp "$settings_file" "$backup_file"

        # Show what other keys exist that we're preserving
        local preserved_keys
        preserved_keys=$(jq -r 'keys | map(select(. != "hooks" and . != "statusLine" and . != "model" and . != "permissions")) | join(", ")' "$settings_file" 2>/dev/null)
        if [ -n "$preserved_keys" ]; then
            print_info "Preserving existing settings: $preserved_keys"
        fi
    fi

    # Write the merged configuration
    echo "$new_settings" | jq . > "$settings_file"

    print_success "Claude Code settings configured (merged with existing)"
}

# Uninstall ccmetrics from settings.json
uninstall_ccmetrics_settings() {
    print_step "Removing ccmetrics from Claude Code settings..."

    local settings_file="$CLAUDE_DIR/settings.json"
    local backup_file="$CLAUDE_DIR/settings.json.backup.$(date +%s)"

    if [ ! -f "$settings_file" ]; then
        print_info "No settings.json found, nothing to uninstall"
        return 0
    fi

    if ! has_ccmetrics_hooks "$settings_file"; then
        print_info "ccmetrics hooks not found in settings.json"
        return 0
    fi

    # Generate cleaned configuration
    local cleaned_settings
    cleaned_settings=$(remove_ccmetrics_hooks "$settings_file")

    # Validate JSON
    if ! echo "$cleaned_settings" | jq empty 2>/dev/null; then
        print_error "Failed to generate valid JSON configuration"
        return 1
    fi

    # Dry run: show diff and exit
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY RUN] Would make the following changes:"
        show_settings_diff "$settings_file" "$cleaned_settings"
        print_info "[DRY RUN] No files were modified"
        return 0
    fi

    # Backup before modifying
    print_info "Backing up settings to: $backup_file"
    cp "$settings_file" "$backup_file"

    # Check if settings would be empty after removal
    if echo "$cleaned_settings" | jq -e '. == {}' >/dev/null 2>&1; then
        print_info "Settings file would be empty, removing it"
        rm "$settings_file"
    else
        echo "$cleaned_settings" | jq . > "$settings_file"
    fi

    print_success "ccmetrics hooks removed from settings.json"
    print_info "Backup saved to: $backup_file"
}

#############################################################################
# TESTING
#############################################################################

run_tests() {
    print_step "Running connectivity test..."

    # Read config file
    local config_file="$CLAUDE_DIR/.ccmetrics-config.json"
    if [ ! -f "$config_file" ]; then
        print_error "Config file not found at $config_file"
        return 1
    fi

    local TEST_EMAIL=$(jq -r '.developer_email' "$config_file")
    local TEST_SUPABASE_URL=$(jq -r '.supabase_url' "$config_file")
    local TEST_SUPABASE_KEY=$(jq -r '.supabase_key' "$config_file")

    # Create test payload
    local test_payload=$(jq -n \
        --arg session_id "test-setup-$(date +%s)" \
        --arg developer "$TEST_EMAIL" \
        --arg hostname "$HOSTNAME" \
        '{
            session_id: $session_id,
            developer: $developer,
            hostname: $hostname,
            project_path: "/test/setup",
            duration_minutes: 0.1,
            cost_usd: 0.01,
            input_tokens: 100,
            output_tokens: 50,
            message_count: 1,
            user_message_count: 1,
            tools_used: "test",
            context_usage_percent: 0.08
        }')

    # Test sending to Supabase
    local response=$(curl -s -w "\n%{http_code}" -X POST \
        "${TEST_SUPABASE_URL}/rest/v1/sessions" \
        -H "apikey: ${TEST_SUPABASE_KEY}" \
        -H "Authorization: Bearer ${TEST_SUPABASE_KEY}" \
        -H "Content-Type: application/json" \
        -H "Prefer: return=minimal" \
        -d "$test_payload" \
        --max-time 10 2>&1)

    local http_code=$(echo "$response" | tail -n1)

    if [ "$http_code" = "201" ]; then
        print_success "Successfully connected to Supabase!"
        print_success "Test data sent successfully"
        return 0
    else
        print_error "Failed to connect to Supabase (HTTP $http_code)"
        print_warning "Please verify:"
        print_info "  1. Supabase URL is correct"
        print_info "  2. API key is correct"
        print_info "  3. 'sessions' table exists in your database"
        print_info "  4. Row Level Security (RLS) is disabled or configured correctly"
        return 1
    fi
}

#############################################################################
# MAIN INSTALLATION FLOW
#############################################################################

main() {
    print_header

    # Handle uninstall mode
    if [ "$UNINSTALL" = true ]; then
        print_info "Uninstall mode"
        if [ "$DRY_RUN" = true ]; then
            print_info "[DRY RUN] No files will be modified"
        fi
        echo ""
        check_dependencies
        uninstall_ccmetrics_settings
        if [ "$DRY_RUN" != true ]; then
            echo ""
            print_success "Uninstallation complete"
            print_info "Note: Hook scripts in ~/.claude/hooks/ were not removed"
            print_info "To fully remove, delete: ~/.claude/hooks/ccmetrics_*.sh"
        fi
        return 0
    fi

    # Handle dry-run mode for install
    if [ "$DRY_RUN" = true ]; then
        print_info "[DRY RUN] Previewing settings.json changes only"
        echo ""
        check_dependencies
        configure_claude_settings
        return 0
    fi

    # Checks
    check_not_root
    detect_os
    print_info "Detected OS: $OS"
    echo ""

    # Dependencies
    check_dependencies

    # Configuration
    collect_config

    # Installation
    create_directories
    create_config_file
    download_or_create_hook_script
    create_queue_processor
    create_statusline_script
    configure_claude_settings

    echo ""

    # Testing (only when debug is enabled)
    local config_file="$CLAUDE_DIR/.ccmetrics-config.json"
    local debug_enabled=$(jq -r '.debug // false' "$config_file" 2>/dev/null || echo "false")

    if [ "$debug_enabled" = "true" ]; then
        if run_tests; then
            echo ""
            print_header
            echo -e "${GREEN}✓ Installation Complete!${NC}"
            echo ""
            print_info "Next steps:"
            echo "  1. Start a new Claude Code session"
            echo "  2. The statusline will show real-time usage"
            echo "  3. Session data will be sent to Supabase automatically"
            echo "  4. Check logs: tail -f ~/.claude/ccmetrics.log"
            echo "  5. View queue: ls ~/.claude/metrics_queue/"
            echo ""
            print_info "Documentation:"
            echo "  - Logs: ~/.claude/ccmetrics.log"
            echo "  - Settings: ~/.claude/settings.json"
            echo ""
        else
            echo ""
            print_error "Installation completed but connectivity test failed"
            print_info "Please check the configuration and try again"
            print_info "You can re-run setup with: bash setup_ccmetrics.sh"
            exit 1
        fi
    else
        echo ""
        print_header
        echo -e "${GREEN}✓ Installation Complete!${NC}"
        echo ""
        print_info "Next steps:"
        echo "  1. Start a new Claude Code session"
        echo "  2. The statusline will show real-time usage"
        echo "  3. Session data will be sent to Supabase automatically"
        echo "  4. Check logs: tail -f ~/.claude/ccmetrics.log"
        echo "  5. View queue: ls ~/.claude/metrics_queue/"
        echo ""
        print_info "Documentation:"
        echo "  - Logs: ~/.claude/ccmetrics.log"
        echo "  - Settings: ~/.claude/settings.json"
        echo ""
    fi
}

# Parse arguments and run
parse_args "$@"
main
