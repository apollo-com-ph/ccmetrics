# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Claude Code Metrics Collection - A hook-based system that automatically collects session metadata (cost, duration, tokens) from Claude Code and stores it in a user-controlled Supabase database. Privacy-first design: collects only metadata, never conversation content or code.

## Working Directory Best Practices

Bash tool working directory may reset between commands. Always use absolute paths or explicit `cd` when running commands:
```bash
cd /path/to/project && command    # Change directory first
/path/to/project/script.sh        # Use absolute path
```

## Architecture

**Event-driven hook system:**
- `SessionEnd` hook (`~/.claude/hooks/send_claude_metrics.sh`) - Extracts session metadata from Claude Code's JSON output, sends to Supabase REST API
- `SessionStart` hook (`~/.claude/hooks/process_metrics_queue.sh`) - Calls main hook with `HOOK_EVENT=SessionStart` to retry queued payloads
- Failed sends are queued to `~/.claude/metrics_queue/` as timestamped JSON files (max 100, oldest auto-deleted)

**Data flow:**
1. Claude Code session ends → pipes session JSON to hook via stdin
2. Hook extracts from stdin JSON: `session_id`, `model`, `cost.total_cost_usd`, `cost.total_duration_ms`, `context_window.total_input/output_tokens`
3. Hook calculates `context_usage_percent` from total tokens and model's context limit
4. Hook reads transcript file (if available) to count messages and tools used (no content extraction)
5. POST to Supabase REST API (`/rest/v1/sessions`) with 5-second timeout
6. On failure: queue payload; on success: process up to 10 queued items

**Script structure:** `setup_ccmetrics.sh` is a self-contained installer with embedded heredocs for:
- `send_claude_metrics.sh` (lines 296-555) - main hook with `__SUPABASE_URL__` and `__SUPABASE_KEY__` placeholders
- `process_metrics_queue.sh` (lines 571-582) - wrapper that sets `HOOK_EVENT` env var
- `ccmetrics_statusline.sh` (lines 593-745) - custom statusline showing model, tokens, and context usage
- `settings.json` (lines 779-810) - Claude Code configuration with hooks and statusline

## Commands

**Installation:**
```bash
bash setup_ccmetrics.sh
```

**Verify installation:**
```bash
tail -f ~/.claude/ccmetrics.log        # Check logs
ls -1 ~/.claude/metrics_queue/ | wc -l  # Queue size
ls -l ~/.claude/hooks/                  # Verify hooks
```

**Test Supabase connection:**
```bash
curl -X GET "${SUPABASE_URL}/rest/v1/sessions?limit=1" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}"
```

## Dependencies

Required: `jq`, `bc`, `curl`, `bash`, `sed`, `awk`

Setup script auto-installs jq/bc via apt, yum, brew, or pacman.

## Statusline

Custom bash script (`ccmetrics_statusline.sh`) displays comprehensive session metrics without Node.js dependencies:
- Format: `[Model]%/min/$usd/inK/outK/totK /path`
- Example: `[Sonnet 4.5]28%/0012/$1.2/ 45K/ 12K/ 57K /home/user/projects/myapp`
- Reads session JSON from stdin, extracts model/tokens/percentage/cost/duration/path using jq
- Fixed-width formatting: model (10 chars), percentage (2 digits), duration (4 digits), cost (4 chars), tokens (4 chars each)
- Project path truncates from left if terminal width insufficient
- Easily customizable by editing the script

## Database Schema

```sql
CREATE TABLE sessions (
  id BIGSERIAL PRIMARY KEY,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  session_id TEXT NOT NULL,
  developer TEXT NOT NULL,
  hostname TEXT,
  project_path TEXT,
  duration_minutes NUMERIC(10,2),
  cost_usd NUMERIC(10,4),
  input_tokens INTEGER,
  output_tokens INTEGER,
  message_count INTEGER,
  user_message_count INTEGER,
  tools_used TEXT,
  context_usage_percent NUMERIC(5,2),
  seven_day_utilization INTEGER,
  seven_day_resets_at TIMESTAMPTZ
);
```

RLS must be disabled or have permissive policy for anon key to write.

## Model Context Limits

Context usage percentage is calculated using hardcoded model limits (all currently 200K tokens):
- `claude-opus-4*`, `claude-sonnet-4*`, `claude-haiku-3*`
- `claude-3-5-sonnet*`, `claude-3-5-haiku*`
- `claude-3-opus*`, `claude-3-sonnet*`, `claude-3-haiku*`

Unknown models default to 200K. Update `MODEL_LIMITS` in the hook script if limits change.
