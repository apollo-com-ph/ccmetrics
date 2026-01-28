# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- LICENSE file (MIT)
- CONTRIBUTING.md with contribution guidelines
- CODE_OF_CONDUCT.md
- .gitignore for common exclusions

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
