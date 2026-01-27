# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hook-based system that collects Claude Code session metadata (cost, duration, tokens) and stores it in Supabase. Privacy-first: only metadata, never conversation content or code.

## ⚠️ Bash Tool - ALWAYS Use Full Paths

Shell state resets between commands. **NEVER run bare commands like `git status`.**

```bash
# CORRECT:
git -C /home/jessie/cc_workspace/ccmetrics status
cd /home/jessie/cc_workspace/ccmetrics && git status

# WRONG - will fail:
git status
```

## Architecture

**Hooks** (in `~/.claude/hooks/`):
- `ccmetrics_statusline.sh` - displays metrics, caches to `~/.claude/metrics_cache/{session_id}.json`
- `send_claude_metrics.sh` - reads cache on SessionEnd, POSTs to Supabase
- `process_metrics_queue.sh` - retries failed sends from `~/.claude/metrics_queue/`

**Config** (`~/.claude/.ccmetrics-config.json`): `developer_email`, `supabase_url`, `supabase_key`

**Data flow:** Statusline caches metrics → SessionEnd reads cache + transcript → POST to Supabase → on failure, queue for retry

## Commands

```bash
bash setup_ccmetrics.sh                   # Install
tail -f ~/.claude/ccmetrics.log           # Check logs
ls ~/.claude/metrics_queue/ | wc -l       # Queue size
```

## Dependencies

`jq`, `bc`, `curl`, `bash` - setup auto-installs jq/bc

## Statusline

Format: `[Model]%/min/$usd/inK/outK/totK /path`
Example: `[Sonnet 4.5]28%/0012/$1.2/ 45K/ 12K/ 57K /home/user/project`

## Database Schema

See `SUPABASE_SETUP.md` for full schema. Key columns: `session_id`, `developer`, `cost_usd`, `input_tokens`, `output_tokens`, `duration_minutes`, `model`, `claude_account_email`.

RLS enabled with write-only policy (INSERT only) - developers can submit but not read/delete data.
