# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Hook-based system that collects Claude Code session metadata (cost, duration, tokens) and stores it in Supabase. Privacy-first: only metadata, never conversation content or code.

See `README.md` for user-facing install, usage, and troubleshooting docs.

## Architecture

**Hooks** (in `~/.claude/hooks/`):
- `ccmetrics_statusline.sh` - displays metrics, caches to `~/.claude/metrics_cache/{session_id}.json`
- `send_claude_metrics.sh` - reads cache on SessionEnd, POSTs to Supabase
- `process_metrics_queue.sh` - retries failed sends from `~/.claude/metrics_queue/`

**Config** (`~/.claude/.ccmetrics-config.json`): `developer_email`, `supabase_url`, `supabase_key`, `created_at` (ISO timestamp), `debug` (boolean, default false)

**Logging** (`~/.claude/ccmetrics.log`): Single unified log file for both regular and debug entries. All entries include a module tag (`[SESSION_END]` or `[STATUSLINE]`) and a log level (`INFO`, `WARN`, `ERROR`, or `DEBUG`). Debug entries (level `DEBUG`) only appear when `debug=true` in config. Format: `[YYYY-MM-DD HH:MM:SS] [MODULE] LEVEL message`

**Data flow:**
- Statusline caches metrics to `{session_id}.json` → runs background OAuth fetch every 5min (usage/profile) → caches to `_oauth_cache.json`
- **/clear handling:** When `/clear` is used, Claude Code fires `SessionEnd(reason=clear)` then creates a new session with a new `session_id`. Cumulative metrics (cost, tokens, duration) carry over to the new session. SessionEnd hook uses a **baseline delta approach** to compute per-session values:
  - Reads baseline file `_clear_baseline_{project_hash}.json` (if exists)
  - Subtracts baseline from current cumulative to get per-session delta
  - On `reason=clear`: sends delta to Supabase, saves new baseline for next session
  - On normal exit: sends delta, deletes baseline (chain is over)
- SessionEnd reads cache + transcript → computes baseline delta (if in /clear chain) → checks OAuth token expiry → fetches usage/profile with retry (or uses cached fallback if expired) → POST to Supabase (empty payloads skipped) → on failure, queue for retry
- **VS Code compatibility:** The statusline hook fires in VS Code native UI mode (output just isn't displayed), so caching and OAuth work normally. SessionEnd also has a stdin fallback + transcript parsing fallback as defense-in-depth. The statusline output is written to `_statusline.txt` for external consumers (e.g., a VS Code status bar extension).

## Commands

```bash
bash setup_ccmetrics.sh                                    # Install
tail -f ~/.claude/ccmetrics.log                            # Check logs (all levels)
grep '\[SESSION_END\]' ~/.claude/ccmetrics.log             # Filter by module
grep 'ERROR\|WARN' ~/.claude/ccmetrics.log                 # Errors and warnings only
grep 'DEBUG' ~/.claude/ccmetrics.log                       # Debug entries only (requires debug=true)
ls ~/.claude/metrics_queue/ | wc -l                        # Queue size
```

## Dependencies

`jq`, `curl`, `awk` - install before running setup (see README). Note: `awk` and `curl` are pre-installed on most Unix systems.

## Statusline

Format: `[Model]%/$usd (remaining% reset label) parent/project`
Example: `[Sonnet 4.5]38%/$7.4 (72% 4h12m 5h) cc_workspace/ccmetrics`

The parenthetical shows API utilization: remaining capacity %, time until reset, and which limit (5h or 7d). Displays whichever limit has lower remaining %; on tie, shows the one with longer reset time. Shows `(-- ----- --)` when OAuth data is unavailable.

**Cost display after /clear:** The statusline applies the same baseline delta logic as SessionEnd, so the `$usd` portion resets to $0.0 when `/clear` is used and shows only the cost for the current session segment.

## Database Schema

See `SUPABASE_SETUP.md` for full schema. Key columns: `session_id`, `developer`, `cost_usd`, `input_tokens`, `output_tokens`, `duration_minutes`, `model`, `claude_account_email`, `seven_day_utilization`, `five_hour_utilization`, `seven_day_sonnet_utilization` (with corresponding `_resets_at` timestamp columns), `metrics_source` ("cache", "stdin", or "transcript"), `client_type` ("cli" or "vscode").

**/clear sessions:** Each `/clear` creates a new `session_id`. Metrics are computed as per-session deltas using baseline files, so each session row in Supabase contains only the cost/tokens for that segment (not cumulative).

RLS enabled with write-only policy (INSERT only) - developers can submit but not read/delete data.
