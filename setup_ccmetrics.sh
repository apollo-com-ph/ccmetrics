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
    local EXISTING_CREATED_AT=""
    local EXISTING_STATUSLINE=""

    if [ -f "$config_file" ]; then
        print_info "Found existing configuration."
        EXISTING_EMAIL=$(jq -r '.developer_email // empty' "$config_file" 2>/dev/null)
        EXISTING_URL=$(jq -r '.supabase_url // empty' "$config_file" 2>/dev/null)
        EXISTING_KEY=$(jq -r '.supabase_key // empty' "$config_file" 2>/dev/null)
        EXISTING_DEBUG=$(jq -r '.debug // false' "$config_file" 2>/dev/null)
        EXISTING_CREATED_AT=$(jq -r '.created_at // empty' "$config_file" 2>/dev/null)
        EXISTING_STATUSLINE=$(jq -r '.statusline_enabled // true' "$config_file" 2>/dev/null)
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
        local default_email="${USER}@${HOSTNAME:-$(hostname 2>/dev/null || echo 'unknown')}"
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

    # Statusline Configuration
    local EXISTING_STATUSLINE_BOOL="${EXISTING_STATUSLINE:-true}"
    if [ "$EXISTING_STATUSLINE_BOOL" != "true" ] && [ "$EXISTING_STATUSLINE_BOOL" != "false" ]; then
        EXISTING_STATUSLINE_BOOL="true"  # Default to true if invalid
    fi
    
    if [ -n "$EXISTING_STATUSLINE_BOOL" ] && [ "$EXISTING_STATUSLINE_BOOL" = "false" ]; then
        if prompt_overwrite_field "statusline_enabled" "false" false; then
            STATUSLINE_ENABLED="false"
        else
            # Ask if they want to enable it
            print_info "Statusline Configuration"
            echo ""
            echo "  ccmetrics can display a custom statusline showing real-time"
            echo "  cost, context usage, and API utilization."
            echo "  Note: This replaces any existing statusLine in settings.json."
            echo ""
            read -p "Enable ccmetrics statusline? (Y/n): " -n 1 -r
            echo ""
            if [[ $REPLY =~ ^[Nn]$ ]]; then
                STATUSLINE_ENABLED="false"
            else
                STATUSLINE_ENABLED="true"
            fi
        fi
        echo ""
    else
        # No existing config or statusline is true - still prompt on fresh install
        if [ -z "$EXISTING_STATUSLINE" ]; then
            print_info "Statusline Configuration"
            echo ""
            echo "  ccmetrics can display a custom statusline showing real-time"
            echo "  cost, context usage, and API utilization."
            echo "  Note: This replaces any existing statusLine in settings.json."
            echo ""
            read -p "Enable ccmetrics statusline? (Y/n): " -n 1 -r
            echo ""
            if [[ $REPLY =~ ^[Nn]$ ]]; then
                STATUSLINE_ENABLED="false"
            else
                STATUSLINE_ENABLED="true"
            fi
            echo ""
        else
            # Existing config with statusline enabled, keep it
            STATUSLINE_ENABLED="true"
        fi
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

    # Preserve existing created_at if available, otherwise use current time
    local created_at_value="${EXISTING_CREATED_AT:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

    # Create config with jq for proper JSON formatting
    # Create config with jq for proper JSON formatting
    jq -n \
        --arg email "$WORK_EMAIL" \
        --arg url "$SUPABASE_URL" \
        --arg key "$SUPABASE_KEY" \
        --arg created_at "$created_at_value" \
        --argjson debug "$DEBUG_VALUE" \
        --argjson statusline "$STATUSLINE_ENABLED" \
        '{
            developer_email: $email,
            supabase_url: $url,
            supabase_key: $key,
            created_at: $created_at,
            debug: $debug,
            statusline_enabled: $statusline
        }' > "$config_file"
    # Secure the file (only user can read/write)
    chmod 600 "$config_file"

    print_success "Configuration file created at $config_file"
}

install_hook_scripts() {
    print_step "Installing hook scripts..."

    local scripts=(
        "send_claude_metrics.sh"
        "process_metrics_queue.sh"
        "ccmetrics_statusline.sh"
    )

    for script in "${scripts[@]}"; do
        local hook_file="${HOOKS_DIR}/${script}"
        local url="${REPO_URL}/hooks/${script}"

        print_info "Downloading ${script}..."

        if ! curl -fsSL "$url" -o "$hook_file" --max-time 15 2>/dev/null; then
            print_error "Failed to download ${script} from GitHub"
            print_info "Check your internet connection and try again"
            print_info "Or install manually: see README.md \"Manual Installation\" section"
            return 1
        fi

        # Validate: file exists, non-empty, starts with #!/bin/bash
        if [ ! -f "$hook_file" ] || [ ! -s "$hook_file" ]; then
            print_error "Downloaded ${script} is empty or missing"
            return 1
        fi

        if ! head -1 "$hook_file" | grep -q '^#!/bin/bash'; then
            print_error "Downloaded ${script} doesn't appear to be a valid bash script"
            return 1
        fi

        chmod +x "$hook_file"
        print_success "${script} installed"
    done

    print_success "All hook scripts installed"
}


# ccmetrics hook definitions (used for install/uninstall)
get_ccmetrics_config() {
    local include_statusline="${1:-true}"
    
    if [ "$include_statusline" = "true" ]; then
        cat << 'EOF'
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
            "timeout": 20,
            "runInBackground": true
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
    else
        cat << 'EOF'
{
  "hooks": {
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/send_claude_metrics.sh",
            "timeout": 20,
            "runInBackground": true
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
    fi
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
    local include_statusline="${2:-true}"
    local ccmetrics_config
    ccmetrics_config=$(get_ccmetrics_config "$include_statusline")

    if [ -f "$settings_file" ]; then
        # First remove any existing ccmetrics hooks to avoid duplicates
        local cleaned
        cleaned=$(remove_ccmetrics_hooks "$settings_file")

        # Deep merge: existing settings + ccmetrics config
        # For hooks arrays, we append rather than replace
        if [ "$include_statusline" = "true" ]; then
            echo "$cleaned" | jq --argjson cc "$ccmetrics_config" '
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
            echo "$cleaned" | jq --argjson cc "$ccmetrics_config" '
            # Initialize hooks if not present
            .hooks = (.hooks // {}) |

            # Append SessionEnd hooks
            .hooks.SessionEnd = ((.hooks.SessionEnd // []) + $cc.hooks.SessionEnd) |

            # Append SessionStart hooks
            .hooks.SessionStart = ((.hooks.SessionStart // []) + $cc.hooks.SessionStart)
            '
        fi
    else
        # No existing settings, use ccmetrics hooks
        echo "$ccmetrics_config"
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

    # Read statusline preference from config
    local config_file="$CLAUDE_DIR/.ccmetrics-config.json"
    local statusline_enabled="true"
    if [ -f "$config_file" ]; then
        statusline_enabled=$(jq -r '.statusline_enabled // true' "$config_file" 2>/dev/null)
    fi

    # Generate merged configuration
    local new_settings
    new_settings=$(merge_ccmetrics_config "$settings_file" "$statusline_enabled")
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
        preserved_keys=$(jq -r 'keys | map(select(. != "hooks" and . != "statusLine")) | join(", ")' "$settings_file" 2>/dev/null)
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
        --arg hostname "${HOSTNAME:-$(hostname 2>/dev/null || echo 'unknown')}" \
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

# Function to detect VS Code extension and print advisory
detect_vscode_extension() {
    local vscode_ext_dirs=(
        "$HOME/.vscode/extensions"
        "$HOME/.vscode-server/extensions"
    )

    for ext_dir in "${vscode_ext_dirs[@]}"; do
        if [ -d "$ext_dir" ]; then
            if ls "$ext_dir"/anthropic.claude-code* >/dev/null 2>&1; then
                echo ""
                print_info "VS Code Extension Detected"
                echo ""
                print_info "Native UI mode (useTerminal=false):"
                echo "  • Statusline hook does NOT fire"
                echo "  • SessionEnd falls back to transcript parsing"
                echo "  • All metrics recoverable (cost is approximate)"
                echo "  • Statusline output not shown but written to:"
                echo "    ~/.claude/metrics_cache/_statusline.txt"
                echo ""
                print_info "For full metrics support, use terminal mode:"
                echo "  Add to VS Code settings.json: \"claudeCode.useTerminal\": true"
                echo ""
                return 0
            fi
        fi
    done
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
    install_hook_scripts

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

            # Check for VS Code extension
            detect_vscode_extension

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

        # Check for VS Code extension
        detect_vscode_extension

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
