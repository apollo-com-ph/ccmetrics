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
# DEPENDENCY INSTALLATION
#############################################################################

install_jq() {
    print_step "Installing jq (JSON processor)..."
    
    case "$OS" in
        macos)
            if command_exists brew; then
                brew install jq
            else
                print_error "Homebrew not found. Please install Homebrew first:"
                print_info "Visit: https://brew.sh"
                exit 1
            fi
            ;;
        ubuntu|debian)
            sudo apt-get update
            sudo apt-get install -y jq
            ;;
        fedora|rhel|centos)
            sudo yum install -y jq
            ;;
        arch)
            sudo pacman -S jq
            ;;
        *)
            print_error "Unsupported OS for automatic jq installation"
            print_info "Please install jq manually: https://stedolan.github.io/jq/download/"
            exit 1
            ;;
    esac
    
    print_success "jq installed"
}

install_bc() {
    print_step "Installing bc (calculator)..."
    
    case "$OS" in
        macos)
            if command_exists brew; then
                brew install bc
            else
                print_error "Homebrew not found"
                exit 1
            fi
            ;;
        ubuntu|debian)
            sudo apt-get update
            sudo apt-get install -y bc
            ;;
        fedora|rhel|centos)
            sudo yum install -y bc
            ;;
        arch)
            sudo pacman -S bc
            ;;
        *)
            print_error "Unsupported OS for automatic bc installation"
            exit 1
            ;;
    esac
    
    print_success "bc installed"
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
    
    # Check bc
    if ! command_exists bc; then
        print_warning "bc not found"
        missing_deps+=("bc")
    else
        print_success "bc found"
    fi
    
    # Check curl
    if ! command_exists curl; then
        print_error "curl is required but not found"
        print_info "Please install curl and try again"
        exit 1
    else
        print_success "curl found"
    fi

    # Check sed
    if ! command_exists sed; then
        print_error "sed is required but not found"
        print_info "Please install sed and try again"
        exit 1
    else
        print_success "sed found"
    fi

    # Check awk
    if ! command_exists awk; then
        print_error "awk is required but not found"
        print_info "Please install awk and try again"
        exit 1
    else
        print_success "awk found"
    fi
    
    # Install missing dependencies
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo ""
        print_warning "Missing dependencies detected: ${missing_deps[*]}"
        
        # Check if we can auto-install
        if [[ "$OS" == "macos" ]] || [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]] || [[ "$OS" == "fedora" ]]; then
            read -p "Would you like to install them automatically? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                for dep in "${missing_deps[@]}"; do
                    case "$dep" in
                        jq) install_jq ;;
                        bc) install_bc ;;
                    esac
                done
            else
                print_error "Dependencies required. Please install manually and re-run setup"
                exit 1
            fi
        else
            print_error "Please install missing dependencies and re-run setup"
            exit 1
        fi
    fi
    
    echo ""
}

#############################################################################
# CONFIGURATION COLLECTION
#############################################################################

collect_config() {
    print_step "Configuration Setup"
    echo ""
    
    # Supabase URL
    while true; do
        read -p "Enter your Supabase Project URL (e.g., https://xxxxx.supabase.co): " SUPABASE_URL
        if [[ $SUPABASE_URL =~ ^https://.*\.supabase\.co$ ]]; then
            break
        else
            print_error "Invalid Supabase URL format. Should be: https://xxxxx.supabase.co"
        fi
    done
    
    # Supabase API Key
    while true; do
        read -p "Enter your Supabase anon/public API key: " SUPABASE_KEY
        if [ -n "$SUPABASE_KEY" ]; then
            break
        else
            print_error "API key cannot be empty"
        fi
    done
    
    echo ""
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
SUPABASE_URL="__SUPABASE_URL__"
SUPABASE_KEY="__SUPABASE_KEY__"

# Queue configuration
QUEUE_DIR="$HOME/.claude/metrics_queue"
LOG_FILE="$HOME/.claude/ccmetrics.log"
MAX_QUEUE_SIZE=100  # Maximum queued payloads before cleanup

# ============================================================================
# MODEL CONTEXT LIMITS
# ============================================================================
# Model context window limits (tokens)
declare -A MODEL_LIMITS=(
  ["claude-opus-4"]="200000"
  ["claude-sonnet-4"]="200000"
  ["claude-haiku-3"]="200000"
  ["claude-3-5-sonnet"]="200000"
  ["claude-3-5-haiku"]="200000"
  ["claude-3-opus"]="200000"
  ["claude-3-sonnet"]="200000"
  ["claude-3-haiku"]="200000"
)
DEFAULT_LIMIT="200000"

# ============================================================================
# INITIALIZATION
# ============================================================================
mkdir -p "$QUEUE_DIR"
touch "$LOG_FILE"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
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
    process_queue
    exit 0
fi

# Extract session data from stdin
SESSION_DATA=$(cat)

# Validate we have session data
if [ -z "$SESSION_DATA" ] || [ "$SESSION_DATA" = "{}" ]; then
    log "⚠️  No session data received, skipping"
    exit 0
fi

# ============================================================================
# EXTRACT METADATA (NO CONVERSATION CONTENT)
# ============================================================================

SESSION_ID=$(echo "$SESSION_DATA" | jq -r '.session_id // "unknown"')
PROJECT_DIR=$(echo "$SESSION_DATA" | jq -r '.workspace.project_dir // .cwd // "unknown"')
TOTAL_COST=$(echo "$SESSION_DATA" | jq -r '.cost.total_cost_usd // 0')
DURATION_MS=$(echo "$SESSION_DATA" | jq -r '.cost.total_duration_ms // 0')
INPUT_TOKENS=$(echo "$SESSION_DATA" | jq -r '.context_window.total_input_tokens // 0')
OUTPUT_TOKENS=$(echo "$SESSION_DATA" | jq -r '.context_window.total_output_tokens // 0')
TRANSCRIPT_PATH=$(echo "$SESSION_DATA" | jq -r '.transcript_path // ""')
MODEL=$(echo "$SESSION_DATA" | jq -r '.model // "unknown"')

# Calculate duration in minutes
DURATION_MIN=$(echo "scale=2; $DURATION_MS / 60000" | bc 2>/dev/null || echo "0")

# Get context limit for model (match by prefix)
CONTEXT_LIMIT="$DEFAULT_LIMIT"
for model_prefix in "${!MODEL_LIMITS[@]}"; do
  if [[ "$MODEL" == "$model_prefix"* ]]; then
    CONTEXT_LIMIT="${MODEL_LIMITS[$model_prefix]}"
    break
  fi
done

# Calculate context usage percentage
TOTAL_TOKENS=$((INPUT_TOKENS + OUTPUT_TOKENS))
CONTEXT_PERCENT=$(echo "scale=2; $TOTAL_TOKENS * 100 / $CONTEXT_LIMIT" | bc 2>/dev/null || echo "0")

# Count messages WITHOUT reading content
MSG_COUNT=0
USER_MSG_COUNT=0
TOOLS=""

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    MSG_COUNT=$(cat "$TRANSCRIPT_PATH" 2>/dev/null | jq -s '[.[] | select(.type == "user" or .type == "assistant")] | length' || echo 0)
    USER_MSG_COUNT=$(cat "$TRANSCRIPT_PATH" 2>/dev/null | jq -s '[.[] | select(.type == "user")] | length' || echo 0)
    TOOLS=$(cat "$TRANSCRIPT_PATH" 2>/dev/null | jq -s '[.[] | select(.type == "tool_use") | .name] | unique | join(", ")' || echo "")
fi

# ============================================================================
# FETCH USAGE LIMITS
# ============================================================================

SEVEN_DAY_UTIL="null"
SEVEN_DAY_RESETS="null"

CREDENTIALS_FILE="$HOME/.claude/.credentials.json"
if [ -f "$CREDENTIALS_FILE" ]; then
    ACCESS_TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null)
    if [ -n "$ACCESS_TOKEN" ]; then
        USAGE_RESPONSE=$(curl -s --max-time 5 \
            "https://api.anthropic.com/api/oauth/usage" \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -H "Content-Type: application/json" \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "Accept: application/json" 2>/dev/null)

        if [ -n "$USAGE_RESPONSE" ] && ! echo "$USAGE_RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
            SEVEN_DAY_UTIL=$(echo "$USAGE_RESPONSE" | jq -r '.seven_day.utilization // "null"')
            SEVEN_DAY_RESETS=$(echo "$USAGE_RESPONSE" | jq -r '.seven_day.resets_at // "null"')
            log "📈 Usage fetched: 7-day utilization ${SEVEN_DAY_UTIL}%"
        else
            log "⚠️  Failed to fetch usage data"
        fi
    fi
fi

# ============================================================================
# CREATE PAYLOAD
# ============================================================================

PAYLOAD=$(jq -n \
  --arg session_id "$SESSION_ID" \
  --arg developer "$USER" \
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
  --argjson seven_day_util "$SEVEN_DAY_UTIL" \
  --arg seven_day_resets "$SEVEN_DAY_RESETS" \
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
    seven_day_utilization: $seven_day_util,
    seven_day_resets_at: (if $seven_day_resets == "null" then null else $seven_day_resets end)
  }')

# ============================================================================
# SEND TO SUPABASE (WITH QUEUE ON FAILURE)
# ============================================================================

log "📊 Processing session: $SESSION_ID"

if send_to_supabase "$PAYLOAD"; then
    process_queue
else
    queue_payload "$PAYLOAD"
fi

exit 0
HOOKEOF
    
    # Replace placeholders with actual config
    sed -i.bak "s|__SUPABASE_URL__|${SUPABASE_URL}|g" "$hook_file"
    sed -i.bak "s|__SUPABASE_KEY__|${SUPABASE_KEY}|g" "$hook_file"
    rm -f "${hook_file}.bak"
    
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

# Read session data from stdin
INPUT=$(cat)

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
    local rounded=$(echo "($pct + 0.5) / 1" | bc)
    printf "%02d%%" "$rounded"
}

# Format duration: 4 chars, minutes, left padded with 0
format_duration() {
    local ms="$1"
    local minutes=$(echo "($ms + 30000) / 60000" | bc)
    printf "%04d" "$minutes"
}

# Format cost: 4 chars, $0.0 to $999, right padded
format_cost() {
    local cost="$1"

    # Handle zero or very small values
    if [ "$(echo "$cost < 0.05" | bc)" -eq 1 ]; then
        echo "\$0.0"
        return
    fi

    # $0.1-$0.9: "$0.X" (1 decimal)
    if [ "$(echo "$cost < 1.0" | bc)" -eq 1 ]; then
        printf "\$0.%.0f" "$(echo "$cost * 10" | bc | sed 's/\..*//')"
        return
    fi

    # $1.0-$9.9: "$X.X" (1 decimal)
    if [ "$(echo "$cost < 10.0" | bc)" -eq 1 ]; then
        printf "\$%.1f" "$cost"
        return
    fi

    # $10-$99: "$XX " (space padded right)
    if [ "$(echo "$cost < 100.0" | bc)" -eq 1 ]; then
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

    # Convert to K
    local k_value=$(echo "scale=1; $tokens / 1000" | bc)

    # 1000-9999: "X.XK" (1 decimal)
    if [ "$tokens" -lt 10000 ]; then
        printf "%.1fK" "$k_value"
        return
    fi

    # 10000-99999: " XXK" (space padded)
    if [ "$tokens" -lt 100000 ]; then
        local k_int=$(echo "$tokens / 1000" | bc)
        printf "%3dK" "$k_int"
        return
    fi

    # 100000-999999: "XXXK"
    local k_int=$(echo "$tokens / 1000" | bc)
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

configure_claude_settings() {
    print_step "Configuring Claude Code settings..."
    
    local settings_file="$CLAUDE_DIR/settings.json"
    local backup_file="$CLAUDE_DIR/settings.json.backup.$(date +%s)"
    
    # Backup existing settings
    if [ -f "$settings_file" ]; then
        print_info "Backing up existing settings to: $backup_file"
        cp "$settings_file" "$backup_file"
        
        # Merge with existing settings
        local existing_settings=$(cat "$settings_file")
        
        # Check if hooks already exist
        if echo "$existing_settings" | jq -e '.hooks' >/dev/null 2>&1; then
            print_warning "Existing hooks configuration found"
            read -p "Overwrite hooks configuration? (y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_warning "Skipping hooks configuration"
                print_info "You'll need to manually add the hooks to your settings.json"
                return
            fi
        fi
    fi
    
    # Create new settings with hooks
    cat > "$settings_file" << 'SETTINGSEOF'
{
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
            "timeout": 15
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
SETTINGSEOF
    
    print_success "Claude Code settings configured"
}

#############################################################################
# TESTING
#############################################################################

run_tests() {
    print_step "Running connectivity test..."
    
    # Create test payload
    local test_payload=$(jq -n \
        --arg session_id "test-setup-$(date +%s)" \
        --arg developer "$USER" \
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
        "${SUPABASE_URL}/rest/v1/sessions" \
        -H "apikey: ${SUPABASE_KEY}" \
        -H "Authorization: Bearer ${SUPABASE_KEY}" \
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
    download_or_create_hook_script
    create_queue_processor
    create_statusline_script
    configure_claude_settings
    
    echo ""
    
    # Testing
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
        echo "  - Supabase dashboard: ${SUPABASE_URL/https:\/\//https://app.}"
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
}

# Run main installation
main
