# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- LICENSE file (MIT)
- CONTRIBUTING.md with contribution guidelines
- CODE_OF_CONDUCT.md
- .gitignore for common exclusions
- OAuth token expiry detection in SessionEnd hook to prevent API failures on idle sessions
- Retry logic for OAuth API calls (1 retry with 1s delay, skips retry on 401/403)
- Background OAuth data caching in statusline hook (every 5 minutes, runs async)
- Cached OAuth data fallback in SessionEnd hook when token is expired
- Troubleshooting documentation for expired OAuth tokens and idle sessions
- VS Code extension compatibility documentation (README.md)
- `metrics_source` field to database schema ("cache" from statusline or "stdin" from fallback)
- `client_type` field to database schema ("cli" or "vscode")
- VS Code extension detection in `setup_ccmetrics.sh` with advisory about native UI limitations
- VS Code extension detection in `verify_hooks.sh` with compatibility information

### Changed
- Increased SessionEnd hook timeout from 15s to 20s to accommodate retry logic
- OAuth API calls now use 3s timeout (down from 5s) with retry on failure
- Statusline OAuth fetch uses 2s timeout and runs entirely in background (zero impact on rendering)

### Fixed
- OAuth API failures when Claude Code session is left idle overnight (token expires after ~4 hours)
- Null utilization fields and `claude_account_email` in database when token is stale
- Documentation inconsistencies: added missing schema columns (`five_hour_utilization`, `five_hour_resets_at`, `seven_day_sonnet_utilization`, `seven_day_sonnet_resets_at`) to README.md

## [1.0.0] - 2026-01-28

### Added
- Initial public release
- Automated setup script with interactive configuration
- Statusline hook displaying real-time metrics: model, context %, duration, cost, tokens
- Session end hook for Supabase submission
- Retry queue for failed submissions (max 100 items)
- Metrics caching to `~/.claude/metrics_cache/`
- Row Level Security (RLS) with write-only policy
- Support for Claude account email tracking
- 7-day utilization metrics (usage % and reset time)
- Comprehensive documentation (README, SUPABASE_SETUP.md)
- Empty payload filtering (skips sessions with 0 tokens/cost)

### Security
- Config files stored with 600 permissions
- Credentials kept in `~/.claude/.ccmetrics-config.json` (outside repo)
- INSERT-only database policy prevents data exfiltration

### Changed
- Replaced `bc`/`sed` dependencies with `awk` for floating-point math
- Simplified dependency list to: `jq`, `curl`, `awk`

### Fixed
- Variable interpolation in configuration file paths
- Developer email retrieval from config
