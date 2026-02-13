# Claude Code Metrics Collection

Automated metadata collection for Claude Code sessions with Supabase storage and retry queue.

## Features

- ✅ **Metadata-only tracking** (no conversation content)
- ✅ **Automatic retry queue** for network failures
- ✅ **Real-time statusline** showing usage (optional)
- ✅ **Free Supabase storage**
- ✅ **Privacy-first design**
- ✅ **/clear segment tracking** (each conversation segment gets its own row)

## Install

### Prerequisites

- Claude Code installed
- Supabase account with project set up ([see Backend Setup](#backend-setup-supabase))
- `jq` installed (`brew install jq` / `apt install jq` / `dnf install jq`)
- `curl` and `awk` (pre-installed on most Unix systems)

### Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/ccmetrics/main/setup_ccmetrics.sh -o /tmp/setup_ccmetrics.sh && bash /tmp/setup_ccmetrics.sh && rm /tmp/setup_ccmetrics.sh
```

### Setup Prompts

The installer will ask for:

1. **Work email** - Your developer identifier (e.g., `you@company.com`)
2. **Supabase Project URL** - From your Supabase dashboard (e.g., `https://xxxxx.supabase.co`)
3. **Supabase API Key** - Publishable key starting with `sb_publishable_` (from Project Settings > API)
4. **Enable statusline?** (Y/n) - Custom statusline showing real-time cost/usage
   - **Y (default)**: Registers statusline in `settings.json`, replacing any existing statusLine
   - **N**: Hook scripts installed but statusLine not registered (metrics still collected via SessionEnd)

The script safely merges with existing `settings.json`:
- Preserves all existing configuration keys
- Appends hooks without overwriting other hooks
- Creates timestamped backups before any modification
- Validates JSON before writing

### Verify Installation

```bash
# Check logs
tail -f ~/.claude/ccmetrics.log

# Start a Claude Code session
# Metrics will be sent automatically on session end
```

### Setup Options

```bash
# Preview changes without modifying files
bash setup_ccmetrics.sh --dry-run

# Uninstall ccmetrics hooks (preserves other settings)
bash setup_ccmetrics.sh --uninstall

# Preview uninstall changes
bash setup_ccmetrics.sh --uninstall --dry-run
```

### Manual Installation (Advanced)

If you prefer manual installation or need to troubleshoot:

1. **Clone the repository:**
   ```bash
   git clone https://github.com/apollo-com-ph/ccmetrics.git
   cd ccmetrics
   ```

2. **Copy hook scripts:**
   ```bash
   mkdir -p ~/.claude/hooks
   cp hooks/*.sh ~/.claude/hooks/
   chmod +x ~/.claude/hooks/*.sh
   ```

3. **Create config file (`~/.claude/.ccmetrics-config.json`):**
   ```json
   {
     "developer_email": "you@company.com",
     "supabase_url": "https://xxxxx.supabase.co",
     "supabase_key": "sb_publishable_xxxxxxxxxxxx",
     "created_at": "2025-01-15T10:00:00Z",
     "debug": false,
     "statusline_enabled": true
   }
   ```
   Then secure it: `chmod 600 ~/.claude/.ccmetrics-config.json`

4. **Edit `~/.claude/settings.json` to register hooks:**

   Add this to your `settings.json` (or merge with existing hooks):

   ```json
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
   ```

   **Note:** `statusLine` is optional - omit it if you set `statusline_enabled: false` in config.

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

## Usage

### How It Works

Once installed, metrics are collected automatically:

- **SessionEnd**: Data sent to Supabase (skips empty sessions with no tokens/cost)
- **SessionStart**: Retries any queued failed sends
- **StatusLine** (if enabled): Real-time usage display

Empty payloads (0 tokens, $0 cost, unknown model) are automatically skipped to avoid cluttering the database.

### Statusline Display

**Format:** `[Model]%/$usd (remaining% reset) [!warning!] parent/project`

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

### VS Code Extension

If you use Claude Code through the VS Code extension:

1. Run the same install command in any terminal (VS Code's integrated terminal or external)
2. Enter your Supabase URL, API key, and work email when prompted
3. That's it - metrics collection works automatically

**Metrics accuracy:**
- **Native UI mode** (`useTerminal=false`, the default): Statusline hook does NOT fire. SessionEnd falls back to transcript parsing, calculating approximate cost from token counts (base pricing rates only, no cache tier discounts).
- **Terminal mode** (`useTerminal=true`): Full metrics support with real-time cost/token/context data. Recommended for complete accuracy.

To enable terminal mode, add to your VS Code `settings.json`:
```json
"claudeCode.useTerminal": true
```

The statusline output is also written to `~/.claude/metrics_cache/_statusline.txt` for external consumers (e.g., custom VS Code status bar extensions).

### Recommended Settings (Optional)

Apply recommended Claude Code safety and productivity settings:

```bash
bash recommended_cc_settings.sh              # Interactive mode
bash recommended_cc_settings.sh --dry-run    # Preview changes
bash recommended_cc_settings.sh --yes        # Apply all (Relaxed mode)
```

Choose a security level for bash permissions:

| Level | Bash Permissions | Best For |
|-------|------------------|----------|
| **YOLO** | All commands allowed, no deny rules | Experienced users, maximum speed |
| **Relaxed** | All commands, dangerous ones blocked | Daily use, good balance (default) |
| **Balanced** | Whitelist of safe commands only | Unfamiliar codebases |
| **Strict** | Prompt for everything | Sensitive environments, learning |

Other settings: opusplan model (Opus for planning, Sonnet for implementation), plan mode default, GitHub read access, safety guards for `rm -rf`, `git reset --hard`, etc.

See [`recommended_cc_settings.sh`](recommended_cc_settings.sh) for full details.

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

### Disable monitoring

See [Setup Options](#setup-options) for `--uninstall` and `--dry-run` flags.

## Backend Setup (Supabase)

You'll need a Supabase project before installing ccmetrics. Follow the guide in [`SUPABASE_SETUP.md`](SUPABASE_SETUP.md) to:

1. Create a free Supabase project
2. Create the `sessions` table with the correct schema
3. Set up Row Level Security (RLS) policies for write-only access
4. Get your Project URL and publishable API key

**Quick summary:**
- Create project at [supabase.com](https://supabase.com)
- Run the SQL script from `SUPABASE_SETUP.md` to create the table
- Copy your Project URL (Settings > API > Project URL)
- Copy your publishable key (Settings > API > Project API keys > `publishable` key)

Use these values when running `setup_ccmetrics.sh`.

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

## Privacy & Compliance

- Only metadata collected (no conversation content)
- Data stored in your Supabase instance (you control it)
- GDPR-friendly (no PII beyond username/hostname)
- Transparent logging of all operations

## License

MIT

## Support

Issues: https://github.com/apollo-com-ph/ccmetrics/issues
