#!/bin/bash
set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'

# Configuration
readonly SETTINGS_FILE="${HOME}/.claude/settings.json"
readonly BACKUP_SUFFIX=".backup.$(date +%s)"

# Global flags
DRY_RUN=false
YES_MODE=false

# User choices (tracked for building final config)
declare -A CHOICES

# Helper functions
print_header() {
    echo -e "${BOLD}${CYAN}"
    echo "═══════════════════════════════════════════════════════════"
    echo "  Claude Code Recommended Settings"
    echo "═══════════════════════════════════════════════════════════"
    echo -e "${RESET}"
    echo "This script applies recommended safety and productivity settings"
    echo "to your ~/.claude/settings.json file."
    echo ""
    echo "Each setting will be explained and you can choose to apply it."
    echo ""
}

print_section_header() {
    local num=$1
    local title=$2
    local total=${3:-}  # Optional third parameter for total
    local display="[${num}"
    if [[ -n "$total" ]]; then
        display+="/${total}"
    fi
    display+="] ${title}"

    echo -e "${BOLD}${BLUE}"
    echo "──────────────────────────────────────────────────────────────"
    echo "$display"
    echo "──────────────────────────────────────────────────────────────"
    echo -e "${RESET}"
}

print_info() {
    echo -e "${CYAN}$1${RESET}"
}

print_current() {
    echo -e "  ${YELLOW}Current:${RESET} $1"
}

print_recommended() {
    echo -e "  ${GREEN}Recommended:${RESET} $1"
}

print_success() {
    echo -e "${GREEN}✓${RESET} $1"
}

print_skip() {
    echo -e "${YELLOW}⊘${RESET} $1"
}

print_error() {
    echo -e "${RED}✗${RESET} $1"
}

# Prompt for yes/no with default Y
prompt_yn() {
    local prompt=$1
    if [[ "$YES_MODE" == true ]]; then
        echo "y"
        return 0
    fi

    read -p "$(echo -e ${BOLD}${prompt}${RESET}) " response
    response=${response:-y}
    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# Get current setting value using jq
get_current_setting() {
    local key=$1
    local default=$2
    if [[ -f "$SETTINGS_FILE" ]]; then
        jq -r ".${key} // \"${default}\"" "$SETTINGS_FILE" 2>/dev/null || echo "$default"
    else
        echo "$default"
    fi
}

# Check if array contains item
array_contains() {
    local key=$1
    local pattern=$2
    if [[ -f "$SETTINGS_FILE" ]]; then
        jq -e ".${key} // [] | any(. == \"${pattern}\")" "$SETTINGS_FILE" &>/dev/null
    else
        return 1
    fi
}

# Prompt 1: Model Selection
prompt_model() {
    print_section_header "1" "Model Selection" "${TOTAL_SECTIONS}"
    echo ""
    print_info "  The 'opusplan' model uses Opus for planning phases and Sonnet"
    print_info "  for implementation. This provides:"
    echo ""
    echo "  • Deeper analysis during plan mode (Opus excels at reasoning)"
    echo "  • Faster, cost-effective implementation (Sonnet is efficient)"
    echo "  • Best for complex tasks requiring thoughtful architecture"
    echo ""

    local current=$(get_current_setting "model" "sonnet")
    print_current "$current"
    print_recommended "opusplan"
    echo ""

    if prompt_yn "  Apply this setting? (Y/n): "; then
        CHOICES["model"]="opusplan"
        print_success "Model will be set to opusplan"
    else
        print_skip "Keeping current model setting"
    fi
    echo ""
}

# Prompt 2: Default Mode
prompt_default_mode() {
    print_section_header "2" "Default Mode" "${TOTAL_SECTIONS}"
    echo ""
    print_info "  Starting in 'plan' mode means Claude will analyze your request"
    print_info "  and create a detailed implementation plan before making changes."
    echo ""
    echo "  • More thoughtful, structured approach"
    echo "  • Review plans before execution"
    echo "  • Better for complex tasks"
    echo ""

    local current=$(get_current_setting "defaultMode" "none")
    print_current "$current"
    print_recommended "plan"
    echo ""

    if prompt_yn "  Apply this setting? (Y/n): "; then
        CHOICES["defaultMode"]="plan"
        print_success "Default mode will be set to plan"
    else
        print_skip "Keeping current default mode"
    fi
    echo ""
}

# Prompt 3: Security Level
prompt_security_level() {
    print_section_header "3" "Security Level" "${TOTAL_SECTIONS}"
    echo ""
    print_info "  Choose how restrictive Claude's bash permissions should be:"
    echo ""
    echo "  ${BOLD}[Y] YOLO${RESET} - Maximum speed, minimum safety"
    echo "      • Bash(*) allowed, NO deny rules"
    echo "      • Best for: Experienced users who accept all risks"
    echo "      • Trade-off: No guardrails at all"
    echo ""
    echo "  ${BOLD}[R] Relaxed${RESET} - Fast workflow with safety nets (default)"
    echo "      • Bash(*) allowed, dangerous commands blocked"
    echo "      • Best for: Trusted projects, daily use"
    echo "      • Trade-off: Scripts run without prompting"
    echo ""
    echo "  ${BOLD}[B] Balanced${RESET} - Explicit control over permissions"
    echo "      • Whitelist: npm, yarn, git read-ops, pytest, etc."
    echo "      • Scripts (.sh) require separate approval"
    echo "      • Best for: Unfamiliar codebases, reviewing AI actions"
    echo "      • Trade-off: More prompts for uncommon commands"
    echo ""
    echo "  ${BOLD}[S] Strict${RESET} - Maximum security, prompt for everything"
    echo "      • No bash commands auto-allowed"
    echo "      • Every command requires explicit approval"
    echo "      • Best for: Sensitive environments, learning Claude"
    echo "      • Trade-off: Constant permission prompts"
    echo ""

    if [[ "$YES_MODE" == true ]]; then
        CHOICES["security_level"]="relaxed"
        print_success "Security level: relaxed (default)"
        echo ""
        return
    fi

    read -p "$(echo -e ${BOLD}Choose security level [Y/R/B/S] \(default: R\): ${RESET})" choice
    choice=${choice:-R}

    case "$choice" in
        [yY]) CHOICES["security_level"]="yolo" ;;
        [bB]) CHOICES["security_level"]="balanced" ;;
        [sS]) CHOICES["security_level"]="strict" ;;
        *)    CHOICES["security_level"]="relaxed" ;;
    esac

    print_success "Security level: ${CHOICES[security_level]}"
    echo ""
}

# Prompt 4: Bash Allow (Relaxed/Balanced modes)
prompt_bash_allow() {
    local level="${CHOICES[security_level]:-relaxed}"

    # Skip for YOLO (handled in build_new_settings) and Strict (prompts everything)
    if [[ "$level" == "yolo" || "$level" == "strict" ]]; then
        return
    fi

    # Relaxed mode: traditional Bash(*) approach
    if [[ "$level" == "relaxed" ]]; then
        print_section_header "4" "Bash Command Access" "${TOTAL_SECTIONS}"
        echo ""
        print_info "  Allow Claude to run bash commands without prompting for each one."
        print_info "  This includes running shell scripts (.sh files) from any location."
        print_info "  Safety is maintained through deny rules (configured in later steps)."
        echo ""
        echo "  • Faster workflow (no constant permission prompts)"
        echo "  • Safety maintained via deny list for dangerous commands"
        echo "  • Recommended for trusted projects"
        echo ""

        if array_contains "allow" "Bash(*)"; then
            print_current "Bash(*) already allowed"
            print_skip "Skipping (already configured)"
            echo ""
            return
        fi

        print_current "Bash commands require prompts"
        print_recommended "Bash(*) allowed"
        echo ""

        if prompt_yn "  Apply this setting? (Y/n): "; then
            CHOICES["allow_bash"]="yes"
            print_success "Bash commands will be allowed"
        else
            print_skip "Bash commands will continue to require prompts"
        fi
        echo ""
        return
    fi

    # Balanced mode: whitelist approach
    print_section_header "4" "Common Development Commands" "${TOTAL_SECTIONS}"
    echo ""
    print_info "  Allow Claude to run common development commands without prompting."
    print_info "  Uncommon commands will still require approval."
    echo ""
    echo "  Commands that will be allowed:"
    echo "    • Package managers: npm, yarn, pnpm, pip, cargo"
    echo "    • Git (read): status, log, diff, branch, show"
    echo "    • Build/test: make, pytest, jest, cargo build/test"
    echo "    • Runtimes: node, python, python3"
    echo ""
    echo "  Commands that will prompt:"
    echo "    • Shell scripts (.sh files) - see next section"
    echo "    • Git write ops (commit, push, etc.)"
    echo "    • System commands (chmod, chown, etc.)"
    echo ""

    if prompt_yn "  Apply this setting? (Y/n): "; then
        CHOICES["allow_bash_whitelist"]="yes"
        print_success "Common development commands will be allowed"
    else
        print_skip "All bash commands will continue to require prompts"
    fi
    echo ""
}

# Prompt 5: Shell Script Execution (Balanced mode only)
prompt_script_execution() {
    local level="${CHOICES[security_level]:-relaxed}"

    # Only applicable in balanced mode
    if [[ "$level" != "balanced" ]]; then
        return
    fi

    print_section_header "5" "Shell Script Execution" "${TOTAL_SECTIONS}"
    echo ""
    print_info "  Allow Claude to execute shell scripts (.sh files)."
    print_info "  This is more permissive - scripts can run arbitrary commands."
    echo ""
    echo "  • Useful for: running build.sh, test.sh, project scripts"
    echo "  • Risk: Scripts may contain any command"
    echo "  • Recommendation: Enable for trusted projects only"
    echo ""

    if prompt_yn "  Allow shell script execution? (Y/n): "; then
        CHOICES["allow_scripts"]="yes"
        print_success "Shell script execution will be allowed"
    else
        print_skip "Shell scripts will require approval"
    fi
    echo ""
}

# Prompt 6: WebFetch Allow
prompt_webfetch_allow() {
    local level="${CHOICES[security_level]:-relaxed}"

    # Calculate what section number this is
    local section_num=4  # Base: Model, Mode, Security + 1
    if [[ "$level" == "balanced" ]]; then
        section_num=6  # Model, Mode, Security, Dev Cmds, Scripts + 1
    elif [[ "$level" == "relaxed" ]]; then
        section_num=5  # Model, Mode, Security, Bash + 1
    fi

    print_section_header "$section_num" "GitHub Fetch Access" "${TOTAL_SECTIONS}"
    echo ""
    print_info "  Allow Claude to fetch content from GitHub without prompting."
    print_info "  Useful for reading documentation, PRs, and issues."
    echo ""
    echo "  • Smoother workflow when working with GitHub"
    echo "  • Read-only access (fetching content)"
    echo "  • No risk to your repositories"
    echo ""

    if array_contains "allow" "WebFetch(domain:github.com)"; then
        print_current "WebFetch(domain:github.com) already allowed"
        print_skip "Skipping (already configured)"
        echo ""
        return
    fi

    print_current "GitHub fetches require prompts"
    print_recommended "WebFetch(domain:github.com) allowed"
    echo ""

    if prompt_yn "  Apply this setting? (Y/n): "; then
        CHOICES["allow_webfetch"]="yes"
        print_success "GitHub fetches will be allowed"
    else
        print_skip "GitHub fetches will continue to require prompts"
    fi
    echo ""
}

# Prompt 7: File Deletion Guards
prompt_file_deletion_guards() {
    local level="${CHOICES[security_level]:-relaxed}"

    # Skip for YOLO (no deny rules) and Strict (everything prompts anyway)
    if [[ "$level" == "yolo" || "$level" == "strict" ]]; then
        return
    fi

    # Calculate section number
    local section_num=6  # Relaxed: Model, Mode, Security, Bash, GitHub + 1
    if [[ "$level" == "balanced" ]]; then
        section_num=7  # Model, Mode, Security, Dev Cmds, Scripts, GitHub + 1
    fi

    print_section_header "$section_num" "File Deletion Guards" "${TOTAL_SECTIONS}"
    echo ""
    print_info "  These rules prevent bulk or recursive file deletion:"
    echo ""
    echo "  • rm -rf *        Prevent recursive force deletion"
    echo "  • rm -r *         Prevent recursive deletion"
    echo "  • rmdir *         Prevent directory removal with wildcards"
    echo ""

    print_current "No deletion guards configured"
    print_recommended "Block dangerous rm commands"
    echo ""

    if prompt_yn "  Apply these file deletion guards? (Y/n): "; then
        CHOICES["deny_file_deletion"]="yes"
        print_success "File deletion guards will be applied"
    else
        print_skip "No file deletion guards will be added"
    fi
    echo ""
}

# Prompt 8: Git Safety Guards
prompt_git_guards() {
    local level="${CHOICES[security_level]:-relaxed}"

    # Skip for YOLO (no deny rules) and Strict (everything prompts anyway)
    if [[ "$level" == "yolo" || "$level" == "strict" ]]; then
        return
    fi

    # Calculate section number
    local section_num=7  # Relaxed: Model, Mode, Security, Bash, GitHub, File Del + 1
    if [[ "$level" == "balanced" ]]; then
        section_num=8  # Model, Mode, Security, Dev Cmds, Scripts, GitHub, File Del + 1
    fi

    print_section_header "$section_num" "Git Safety Guards" "${TOTAL_SECTIONS}"
    echo ""
    print_info "  These rules prevent destructive git operations:"
    echo ""
    echo "  • git push --force / -f   Prevent force pushes to remote"
    echo "  • git reset --hard        Prevent losing uncommitted changes"
    echo "  • git clean               Prevent removing untracked files"
    echo "  • git checkout --         Prevent discarding file changes"
    echo "  • git restore             Prevent discarding file changes"
    echo "  • git branch -D           Prevent force-deleting branches"
    echo ""

    print_current "No git safety guards configured"
    print_recommended "Block destructive git commands"
    echo ""

    if prompt_yn "  Apply these git safety guards? (Y/n): "; then
        CHOICES["deny_git"]="yes"
        print_success "Git safety guards will be applied"
    else
        print_skip "No git safety guards will be added"
    fi
    echo ""
}

# Prompt 9: API & Misc Guards
prompt_api_misc_guards() {
    local level="${CHOICES[security_level]:-relaxed}"

    # Skip for YOLO (no deny rules) and Strict (everything prompts anyway)
    if [[ "$level" == "yolo" || "$level" == "strict" ]]; then
        return
    fi

    # Calculate section number
    local section_num=8  # Relaxed: Model, Mode, Security, Bash, GitHub, File Del, Git + 1
    if [[ "$level" == "balanced" ]]; then
        section_num=9  # Model, Mode, Security, Dev Cmds, Scripts, GitHub, File Del, Git + 1
    fi

    print_section_header "$section_num" "API & Miscellaneous Guards" "${TOTAL_SECTIONS}"
    echo ""
    print_info "  Additional safety rules:"
    echo ""
    echo "  • gh api -X DELETE/PUT/POST   Prevent GitHub API mutations"
    echo "  • chmod -R 777                Prevent dangerous permission changes"
    echo "  • > (redirection)             Prevent file truncation"
    echo "  • sed -i                      Encourage using Edit tool instead"
    echo ""

    print_current "No API/misc guards configured"
    print_recommended "Block dangerous operations"
    echo ""

    if prompt_yn "  Apply these guards? (Y/n): "; then
        CHOICES["deny_misc"]="yes"
        print_success "API & miscellaneous guards will be applied"
    else
        print_skip "No API/misc guards will be added"
    fi
    echo ""
}

# Build new settings based on user choices
build_new_settings() {
    local new_settings="{}"

    # Add model
    if [[ -n "${CHOICES[model]:-}" ]]; then
        new_settings=$(echo "$new_settings" | jq ". + {\"model\": \"${CHOICES[model]}\"}")
    fi

    # Add defaultMode
    if [[ -n "${CHOICES[defaultMode]:-}" ]]; then
        new_settings=$(echo "$new_settings" | jq ". + {\"defaultMode\": \"${CHOICES[defaultMode]}\"}")
    fi

    # Build allow array based on security level
    local allow_items=()
    local level="${CHOICES[security_level]:-relaxed}"

    case "$level" in
        yolo)
            # YOLO: Bash(*) with no deny rules
            allow_items+=("Bash(*)")
            ;;
        relaxed)
            # Relaxed: Bash(*) with deny rules
            [[ "${CHOICES[allow_bash]:-}" == "yes" ]] && allow_items+=("Bash(*)")
            ;;
        balanced)
            # Balanced: Whitelist + optional scripts
            if [[ "${CHOICES[allow_bash_whitelist]:-}" == "yes" ]]; then
                # Package managers
                allow_items+=("Bash(npm *)" "Bash(npm)" "Bash(npx *)")
                allow_items+=("Bash(yarn *)" "Bash(yarn)")
                allow_items+=("Bash(pnpm *)" "Bash(pnpm)")
                allow_items+=("Bash(pip install *)" "Bash(pip3 install *)" "Bash(pip list*)" "Bash(pip show *)")
                allow_items+=("Bash(cargo *)")
                allow_items+=("Bash(go get *)" "Bash(go build *)" "Bash(go test *)" "Bash(go run *)")

                # Git read operations (write ops excluded for safety)
                allow_items+=("Bash(git status*)" "Bash(git log *)" "Bash(git log)")
                allow_items+=("Bash(git diff *)" "Bash(git diff)" "Bash(git branch*)")
                allow_items+=("Bash(git show *)" "Bash(git remote *)")

                # Build/test tools
                allow_items+=("Bash(make *)" "Bash(make)")
                allow_items+=("Bash(pytest *)" "Bash(pytest)")
                allow_items+=("Bash(jest *)" "Bash(jest)")
                allow_items+=("Bash(cargo build*)" "Bash(cargo test*)" "Bash(cargo run*)")

                # Runtimes
                allow_items+=("Bash(node *)" "Bash(python *)" "Bash(python3 *)")
            fi

            # Scripts (if user accepted)
            if [[ "${CHOICES[allow_scripts]:-}" == "yes" ]]; then
                allow_items+=("Bash(bash *)" "Bash(sh *)" "Bash(./*.sh)")
            fi
            ;;
        strict)
            # Strict: No bash auto-allow (empty allow_items for bash)
            # User will be prompted for every command
            ;;
    esac

    # Add WebFetch (applies to all levels)
    [[ "${CHOICES[allow_webfetch]:-}" == "yes" ]] && allow_items+=("WebFetch(domain:github.com)")

    if [[ ${#allow_items[@]} -gt 0 ]]; then
        local allow_json=$(printf '%s\n' "${allow_items[@]}" | jq -R . | jq -s .)
        new_settings=$(echo "$new_settings" | jq ". + {\"allow\": $allow_json}")
    fi

    # Build deny array (skip for YOLO and Strict)
    local deny_items=()

    if [[ "$level" != "yolo" && "$level" != "strict" ]]; then
        if [[ "${CHOICES[deny_file_deletion]:-}" == "yes" ]]; then
            deny_items+=("rm -rf *" "rm -r *" "rmdir *")
        fi

        if [[ "${CHOICES[deny_git]:-}" == "yes" ]]; then
            deny_items+=("git push --force *" "git push -f *" "git reset --hard *" "git clean *" "git checkout -- *" "git restore *" "git branch -D *")
        fi

        if [[ "${CHOICES[deny_misc]:-}" == "yes" ]]; then
            deny_items+=("gh api -X DELETE *" "gh api -X PUT *" "gh api -X POST *" "chmod -R 777 *" "> *" "sed -i *")
        fi
    fi

    if [[ ${#deny_items[@]} -gt 0 ]]; then
        local deny_json=$(printf '%s\n' "${deny_items[@]}" | jq -R . | jq -s .)
        new_settings=$(echo "$new_settings" | jq ". + {\"deny\": $deny_json}")
    fi

    echo "$new_settings"
}

# Deep merge settings
merge_settings() {
    local existing=$1
    local new=$2

    # Use jq to perform deep merge
    # For scalar values: new overrides existing
    # For arrays (allow/deny): combine and deduplicate
    jq -s '
        def deep_merge:
            reduce .[] as $item ({};
                . * $item
            );

        .[0] as $existing |
        .[1] as $new |

        # Start with existing
        $existing |

        # Merge scalar fields from new
        if $new.model then .model = $new.model else . end |
        if $new.defaultMode then .defaultMode = $new.defaultMode else . end |

        # Merge allow array (combine and dedupe)
        if $new.allow then
            .allow = ((.allow // []) + ($new.allow // []) | unique)
        else . end |

        # Merge deny array (combine and dedupe)
        if $new.deny then
            .deny = ((.deny // []) + ($new.deny // []) | unique)
        else . end
    ' <(echo "$existing") <(echo "$new")
}

# Preview diff
preview_diff() {
    local original=$1
    local merged=$2

    echo -e "${BOLD}${CYAN}"
    echo "══════════════════════════════════════════════════════════════"
    echo "  Preview of Changes"
    echo "══════════════════════════════════════════════════════════════"
    echo -e "${RESET}"

    # Create temp files for diff
    local temp_before=$(mktemp)
    local temp_after=$(mktemp)

    echo "$original" | jq --sort-keys . > "$temp_before"
    echo "$merged" | jq --sort-keys . > "$temp_after"

    # Show unified diff with color
    if command -v diff &>/dev/null; then
        diff -u "$temp_before" "$temp_after" | tail -n +3 | while IFS= read -r line; do
            if [[ "$line" =~ ^- ]]; then
                echo -e "${RED}${line}${RESET}"
            elif [[ "$line" =~ ^\+ ]]; then
                echo -e "${GREEN}${line}${RESET}"
            else
                echo "$line"
            fi
        done || true  # diff returns non-zero when files differ
    else
        echo -e "${YELLOW}(diff command not available, showing merged result)${RESET}"
        echo "$merged" | jq --sort-keys .
    fi

    rm -f "$temp_before" "$temp_after"
    echo ""
}

# Write settings with backup
write_settings() {
    local content=$1

    # Create ~/.claude directory if it doesn't exist
    mkdir -p "$(dirname "$SETTINGS_FILE")"

    # Backup existing file
    if [[ -f "$SETTINGS_FILE" ]]; then
        cp "$SETTINGS_FILE" "${SETTINGS_FILE}${BACKUP_SUFFIX}"
        print_success "Backup created: ${SETTINGS_FILE}${BACKUP_SUFFIX}"
    fi

    # Write new settings
    echo "$content" | jq --sort-keys . > "$SETTINGS_FILE"
    print_success "Settings written to: $SETTINGS_FILE"
}

# Show help
show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Apply recommended Claude Code safety and productivity settings interactively.

OPTIONS:
    --dry-run       Preview changes without modifying files
    -y, --yes       Accept all defaults (non-interactive mode)
    -h, --help      Show this help message

EXAMPLES:
    $(basename "$0")              # Interactive mode
    $(basename "$0") --dry-run    # Preview changes
    $(basename "$0") --yes        # Apply all recommendations

EOF
}

# Calculate total sections based on security level
calculate_total_sections() {
    local level="${CHOICES[security_level]:-relaxed}"
    case "$level" in
        yolo)   echo "5" ;;  # Model, Mode, Security, GitHub, Final
        strict) echo "5" ;;  # Model, Mode, Security, GitHub, Final
        balanced) echo "9" ;;  # Model, Mode, Security, Dev Cmds, Scripts, GitHub, File Del, Git, API
        *)      echo "8" ;;  # Relaxed: Model, Mode, Security, Bash, GitHub, File Del, Git, API
    esac
}

# Update current section counter
increment_section() {
    CURRENT_SECTION=$((CURRENT_SECTION + 1))
}

# Main function
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -y|--yes)
                YES_MODE=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # Print header
    print_header

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}${BOLD}DRY RUN MODE${RESET} - No changes will be made"
        echo ""
    fi

    if [[ "$YES_MODE" == true ]]; then
        echo -e "${GREEN}${BOLD}NON-INTERACTIVE MODE${RESET} - Applying all recommendations"
        echo ""
    fi

    # Initialize section counter (will be updated after security level is chosen)
    TOTAL_SECTIONS="7"  # Temporary, will be recalculated

    # Run prompts in order
    prompt_model
    prompt_default_mode
    prompt_security_level

    # Now calculate actual total sections based on security level
    TOTAL_SECTIONS=$(calculate_total_sections)

    # Continue with remaining prompts (each calculates its own section number)
    prompt_bash_allow
    prompt_script_execution
    prompt_webfetch_allow
    prompt_file_deletion_guards
    prompt_git_guards
    prompt_api_misc_guards

    # Check if any choices were made
    # Use parameter expansion with + to avoid unbound variable error
    if [[ -z "${CHOICES[@]+_}" ]] || [[ ${#CHOICES[@]} -eq 0 ]]; then
        print_info "No changes selected. Exiting."
        exit 0
    fi

    # Build new settings
    local new_settings=$(build_new_settings)

    # Read existing settings
    local existing_settings="{}"
    if [[ -f "$SETTINGS_FILE" ]]; then
        existing_settings=$(cat "$SETTINGS_FILE")
    fi

    # Merge settings
    local merged_settings=$(merge_settings "$existing_settings" "$new_settings")

    # Preview diff
    preview_diff "$existing_settings" "$merged_settings"

    # Dry run check
    if [[ "$DRY_RUN" == true ]]; then
        print_info "Dry run complete. No changes were made."
        exit 0
    fi

    # Final confirmation
    echo -e "${BOLD}${YELLOW}"
    echo "══════════════════════════════════════════════════════════════"
    echo "  Ready to Apply Changes"
    echo "══════════════════════════════════════════════════════════════"
    echo -e "${RESET}"

    if ! prompt_yn "  Apply these settings? (Y/n): "; then
        print_info "Settings not applied. Exiting."
        exit 0
    fi

    # Write settings
    write_settings "$merged_settings"

    echo ""
    echo -e "${GREEN}${BOLD}✓ Settings applied successfully!${RESET}"
    echo ""
    print_info "Your Claude Code configuration has been updated with recommended settings."
    print_info "Start a new Claude Code session for the changes to take effect."
    echo ""
}

# Run main
main "$@"
