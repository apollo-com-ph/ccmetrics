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
- `Statusline` hook (`~/.claude/hooks/ccmetrics_statusline.sh`) - Displays session metrics, caches data for SessionEnd
- `SessionEnd` hook (`~/.claude/hooks/send_claude_metrics.sh`) - Reads cached metrics, sends to Supabase REST API
- `SessionStart` hook (`~/.claude/hooks/process_metrics_queue.sh`) - Retries queued payloads, cleans up stale cache
- Failed sends are queued to `~/.claude/metrics_queue/` as timestamped JSON files (max 100, oldest auto-deleted)
- Metrics cache stored in `~/.claude/metrics_cache/` (one file per session_id)

**Data flow:**
1. During session: Statusline hook receives pre-calculated stats from Claude Code, caches to `~/.claude/metrics_cache/{session_id}.json`
2. Session ends → SessionEnd hook reads cached metrics (cost, tokens, duration, context %)
3. Hook reads transcript file to count messages and extract tools used (no content extraction)
4. Payload logged to `~/.claude/ccmetrics.log` before sending
5. POST to Supabase REST API (`/rest/v1/sessions`) with 5-second timeout
6. On failure: queue payload; on success: process up to 10 queued items
7. Cache file deleted after successful read; stale files cleaned up after 30 days

**Script structure:** `setup_ccmetrics.sh` is a self-contained installer with embedded heredocs for:
- `send_claude_metrics.sh` (lines 296-562) - main hook with `__SUPABASE_URL__` and `__SUPABASE_KEY__` placeholders
- `process_metrics_queue.sh` (lines 578-589) - wrapper that sets `HOOK_EVENT` env var
- `ccmetrics_statusline.sh` (lines 600-762) - custom statusline showing model, tokens, and context usage
- `settings.json` (lines 796-827) - Claude Code configuration with hooks and statusline

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
- **Caches session data** to `~/.claude/metrics_cache/{session_id}.json` for SessionEnd hook
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
  model TEXT,
  seven_day_utilization INTEGER,
  seven_day_resets_at TIMESTAMPTZ
);
```

**To add model column to existing table:**
```sql
ALTER TABLE sessions ADD COLUMN model TEXT;
```

RLS must be disabled or have permissive policy for anon key to write.

## Metrics Cache

Session metrics (cost, tokens, duration, context %) are cached by the statusline hook and read by the SessionEnd hook:
- Cache location: `~/.claude/metrics_cache/{session_id}.json`
- Contains pre-calculated values from Claude Code (no manual calculation needed)
- Cache file deleted after SessionEnd reads it
- Stale files (older than 30 days) cleaned up on SessionStart

**Note:** If cache file doesn't exist (very short session where statusline never ran), defaults to zero values.
