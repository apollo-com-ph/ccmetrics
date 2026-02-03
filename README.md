# Claude Code Metrics Collection

Automated metadata collection for Claude Code sessions with Supabase storage and retry queue.

## Features

- ✅ **Metadata-only tracking** (no conversation content)
- ✅ **Automatic retry queue** for network failures
- ✅ **Real-time statusline** showing usage
- ✅ **Free Supabase storage**
- ✅ **Privacy-first design**
- ✅ **/clear segment tracking** (each conversation segment gets its own row)

## Quick Install
```bash
curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/ccmetrics/main/setup_ccmetrics.sh -o /tmp/setup_ccmetrics.sh && bash /tmp/setup_ccmetrics.sh && rm /tmp/setup_ccmetrics.sh
```

## What Gets Tracked

**Collected (metadata only):**
- Session ID, timestamp
- Developer work email, hostname
- Claude account email (Anthropic account identity)
- Project directory path
- Duration, cost, token counts
- Context usage percentage (% of model's context window used)
- Tools used (Edit, Write, Bash, etc.)
- Message counts
- Utilization metrics: 7-day usage %, 5-hour usage %, 7-day Sonnet usage % (with reset times)

**NOT collected:**
- Conversation content
- Actual prompts or responses
- Code snippets
- File contents

## Prerequisites

- Claude Code installed
- Supabase account (free tier)
- `jq` installed (`brew install jq` / `apt install jq` / `dnf install jq`)
- `curl` and `awk` (pre-installed on most Unix systems)

## Setup

### 1. Create Supabase Project

Follow [`SUPABASE_SETUP.md`](SUPABASE_SETUP.md) to create the project, `sessions` table, and RLS policies. You'll need your Project URL and API key for step 2.

### 2. Run Setup Script

Run the Quick Install command above, then enter your Supabase URL, API key, and work email when prompted.

#### Setup Options

```bash
# Preview changes without modifying files
bash setup_ccmetrics.sh --dry-run

# Uninstall ccmetrics hooks (preserves other settings)
bash setup_ccmetrics.sh --uninstall

# Preview uninstall changes
bash setup_ccmetrics.sh --uninstall --dry-run
```

The setup script safely merges with existing `settings.json`:
- Preserves all existing configuration keys
- Appends hooks without overwriting other hooks
- Creates timestamped backups before any modification
- Validates JSON before writing
- Sets default model to `opusplan` and permission mode to `plan`

### 3. Verify Installation
```bash
# Check logs
tail -f ~/.claude/ccmetrics.log

# Start Claude Code session
# Session data will be sent automatically on session end
```

## Recommended Settings (Optional)

After installing ccmetrics, you can optionally apply recommended Claude Code safety and productivity settings:

```bash
bash recommended_cc_settings.sh              # Interactive mode
bash recommended_cc_settings.sh --dry-run    # Preview changes
bash recommended_cc_settings.sh --yes        # Apply all recommendations (Relaxed mode)
```

This interactive script lets you choose a security level for bash permissions:

### Security Levels

| Level | Bash Permissions | Deny Rules | Best For |
|-------|------------------|------------|----------|
| **YOLO** | `Bash(*)` allowed, NO deny rules | None | Experienced users who accept all risks, maximum speed |
| **Relaxed** (default) | `Bash(*)` allowed, dangerous commands blocked | Full deny list | Trusted projects, daily use, good balance |
| **Balanced** | Whitelist of safe commands (npm, git read-ops, pytest, etc.) | Full deny list | Unfamiliar codebases, explicit control |
| **Strict** | No auto-allow, prompt for everything | N/A | Sensitive environments, learning Claude |

### Settings Configured

| Setting | Description |
|---------|-------------|
| **Model: opusplan** | Uses Opus for planning (deep reasoning) and Sonnet for implementation (fast, cost-effective) |
| **Default Mode: plan** | Start sessions in plan mode for thoughtful analysis before making changes |
| **Bash Permissions** | Based on your chosen security level (see table above) |
| **GitHub Fetch Allow** | Fetch from GitHub without prompts (read-only access) |
| **File Deletion Guards** | Block `rm -rf *`, `rm -r *`, `rmdir *` (Relaxed/Balanced only) |
| **Git Safety Guards** | Block force push, reset --hard, clean, restore, branch -D (Relaxed/Balanced only) |
| **API/Misc Guards** | Block GitHub API mutations, chmod 777, file redirection, sed -i (Relaxed/Balanced only) |

The script safely merges with your existing `~/.claude/settings.json` and creates a backup before making changes. Each setting is explained with current vs. recommended values.

## Usage

Once installed, metrics are collected automatically:

- **SessionEnd**: Data sent to Supabase (skips empty sessions with no tokens/cost)
- **SessionStart**: Retries any queued failed sends
- **StatusLine**: Real-time usage display (if configured)

Empty payloads (0 tokens, $0 cost, unknown model) are automatically skipped to avoid cluttering the database.

## Using with the VS Code Claude Code Extension

If you use Claude Code through the VS Code extension instead of the CLI, follow these steps:

### Setup

1. Open a terminal (VS Code's integrated terminal or any external terminal)
2. Run the same install command:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/ccmetrics/main/setup_ccmetrics.sh -o /tmp/setup_ccmetrics.sh && bash /tmp/setup_ccmetrics.sh && rm /tmp/setup_ccmetrics.sh
   ```
3. Enter your Supabase URL, API key, and work email when prompted
4. That's it. All features work automatically (metrics, utilization, retry queue).

### Statusline in VS Code

**Native UI mode (`useTerminal=false`, the default):** The statusline hook does NOT fire in VS Code's native UI mode. Metrics collection still works but uses transcript parsing as a fallback at session end, calculating approximate cost from token counts. This results in slightly less precise cost tracking (base pricing rates only, no cache tier discounts).

**Terminal mode (`useTerminal=true`):** Full metrics support with real-time cost/token/context data. Recommended for complete tracking accuracy.

To enable terminal mode, add this to your VS Code `settings.json` (Ctrl/Cmd+Shift+P → "Preferences: Open User Settings (JSON)"):

```json
"claudeCode.useTerminal": true
```

Then reload VS Code. Terminal mode gives you the same experience as the CLI, including the visible statusline.

## Statusline Display

Format: `[Model]%/$usd (remaining% reset) [!warning!] parent/project`

**Examples:**
```
# Normal: 7d usage is sustainable
[Sonnet 4.5]38%/$7.4 (72% 4h12m) cc_workspace/ccmetrics

# Warning: 7d usage exceeds sustainable rate
[Sonnet 4.5]38%/$7.4 (72% 4h12m) !15% 6d13h! cc_workspace/ccmetrics
```

**Display logic:**
- **Always shows 5h limits:** Primary display showing remaining % and time until reset
- **Conditional 7d warning:** Appears only when your 7-day usage exceeds the sustainable rate (14.28% per day)
  - Threshold is dynamic based on days elapsed: `days_elapsed × 14.28%`
  - Example: At day 3, threshold is 42.84% - warning shows if you've used more than that
- Shows `(-- -----)` when OAuth data is unavailable

To customize, edit `~/.claude/hooks/ccmetrics_statusline.sh` -- see comments in the script for available fields and formatting functions.

## Monitoring

### Check Queue Status
```bash
# View queue size
ls -1 ~/.claude/metrics_queue/ | wc -l

# View queue contents
ls -lth ~/.claude/metrics_queue/

# Check sync log
tail -20 ~/.claude/ccmetrics.log
```

### Query Data in Supabase

See [`SUPABASE_SETUP.md`](SUPABASE_SETUP.md#useful-sql-queries) for example queries.

## Files Created
```
~/.claude/
├── settings.json                    # Claude Code configuration
├── .ccmetrics-config.json           # Credentials (chmod 600)
├── ccmetrics.log                    # Sync activity log
├── metrics_queue/                   # Retry queue for failed sends
│   └── [timestamp]_[uuid].json
├── metrics_cache/                   # Session data cache for SessionEnd
│   ├── [session_id].json            # Per-session metrics
│   ├── _oauth_cache.json            # Shared OAuth cache (updated every 5min)
│   ├── _statusline.txt              # Statusline output for VS Code
│   └── _clear_baseline_*.json       # Per-project /clear delta tracking
└── hooks/
    ├── send_claude_metrics.sh       # Main metrics collection hook
    ├── process_metrics_queue.sh     # Queue processor (SessionStart)
    └── ccmetrics_statusline.sh      # Custom statusline (context usage focus)
```

## Troubleshooting

### Queue Management

Failed submissions are queued in `~/.claude/metrics_queue/`. The queue has a maximum size of 100 items - oldest entries are automatically removed when exceeded.

### Hook not running
```bash
# Check settings
cat ~/.claude/settings.json

# Verify hook is executable
ls -l ~/.claude/hooks/send_claude_metrics.sh

# Test manually
echo '{}' | ~/.claude/hooks/send_claude_metrics.sh
```

### Data not appearing in Supabase
```bash
# Check logs
tail -20 ~/.claude/ccmetrics.log

# Check queue
ls ~/.claude/metrics_queue/
```

See [`SUPABASE_SETUP.md`](SUPABASE_SETUP.md#step-6-test-connection) for connection test commands.

### OAuth token expired / idle sessions

If you leave a Claude Code session idle overnight, the OAuth token may expire (~4 hour lifespan). This can cause utilization metrics and Claude account email to be null in the database.

The hooks now include:
- **Token expiry detection** - checks if the token expired before making API calls
- **Automatic retry** - retries failed API calls once with 1-second delay
- **Cached fallback** - statusline hook caches OAuth data every 5 minutes in the background; SessionEnd uses this if the token is expired

Check the logs for expiry warnings:
```bash
tail -f ~/.claude/ccmetrics.log
# Look for: "⚠️  OAuth token expired X.Xh ago (session was idle). Usage/profile data will use cached fallback."
```

The cached data is automatically cleaned up and has minimal performance impact (runs in background, never blocks statusline rendering).

### Disable monitoring

See [Setup Options](#setup-options) for `--uninstall` and `--dry-run` flags.

## Privacy & Compliance

- Only metadata collected (no conversation content)
- Data stored in your Supabase instance (you control it)
- GDPR-friendly (no PII beyond username/hostname)
- Transparent logging of all operations

## License

MIT

## Support

Issues: https://github.com/apollo-com-ph/ccmetrics/issues
