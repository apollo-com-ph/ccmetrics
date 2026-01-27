# Claude Code Metrics Collection

Automated metadata collection for Claude Code sessions with Supabase storage and retry queue.

## Features

- ✅ **Metadata-only tracking** (no conversation content)
- ✅ **Automatic retry queue** for network failures
- ✅ **Real-time statusline** showing usage
- ✅ **Free Supabase storage**
- ✅ **Privacy-first design**

## Quick Install
```bash
curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/ccmetrics/main/setup_ccmetrics.sh | bash
```

Or download and inspect first:
```bash
curl -O https://raw.githubusercontent.com/apollo-com-ph/ccmetrics/main/setup_ccmetrics.sh
bash setup_ccmetrics.sh
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
- 7-day utilization metrics (usage % and reset time)

**NOT collected:**
- Conversation content
- Actual prompts or responses
- Code snippets
- File contents

## Prerequisites

- Claude Code installed
- Supabase account (free tier)
- Dependencies: `jq`, `bc`, `curl`, `sed`, `awk`

Install before running setup:
```bash
# macOS
brew install jq bc curl

# Ubuntu/Debian
sudo apt install jq bc curl

# Fedora/RHEL
sudo dnf install jq bc curl
```

Note: `sed`, `awk`, and `curl` are pre-installed on most Unix systems.

## Setup

### 1. Create Supabase Project

1. Go to [supabase.com](https://supabase.com)
2. Create new project (free tier)
3. Create table:
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
  seven_day_resets_at TIMESTAMPTZ,
  claude_account_email TEXT
);

CREATE INDEX idx_developer ON sessions(developer);
CREATE INDEX idx_created_at ON sessions(created_at);
```

4. Get credentials from Settings → API:
   - Project URL
   - Publishable key (starts with `sb_publishable_`) or legacy `anon` public key

### 2. Run Setup Script
```bash
curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/ccmetrics/main/setup_ccmetrics.sh | bash
```

Enter your Supabase URL, API key, and work email when prompted.

### 3. Verify Installation
```bash
# Check logs
tail -f ~/.claude/ccmetrics.log

# Start Claude Code session
# Session data will be sent automatically on session end
```

## Usage

Once installed, metrics are collected automatically:

- **SessionEnd**: Data sent to Supabase (skips empty sessions with no tokens/cost)
- **SessionStart**: Retries any queued failed sends
- **StatusLine**: Real-time usage display (if configured)

Empty payloads (0 tokens, $0 cost, unknown model) are automatically skipped to avoid cluttering the database.

## Statusline Display

The setup script installs a custom statusline that shows comprehensive session metrics in a compact format:
- Model name (10 chars, padded)
- Context usage percentage (2 digits)
- Duration in minutes (4 digits)
- Cost in USD (4 chars)
- Token counts: input/output/total (4 chars each)
- Full project path (truncated if terminal too narrow)

Example output:
```
[Sonnet 4.5]28%/0012/$1.2/ 45K/ 12K/ 57K /home/user/projects/myapp
```

Format breakdown:
- `[Sonnet 4.5]` - Model name (10 chars max)
- `28%` - Context usage (00-99%)
- `0012` - Duration (0001-9999 minutes)
- `$1.2` - Cost ($0.0-$999)
- `45K` - Input tokens (0-999 or X.XK-999K)
- `12K` - Output tokens (0-999 or X.XK-999K)
- `57K` - Total tokens (0-999 or X.XK-999K)
- `/home/user/projects/myapp` - Project directory

### Customizing the Statusline

Edit `~/.claude/hooks/ccmetrics_statusline.sh` to customize the display format. The script receives session data as JSON via stdin and can access:

- **Model**: `.model.display_name` or `.model.id`
- **Tokens**: `.context_window.total_input_tokens`, `.context_window.total_output_tokens`
- **Context %**: `.context_window.used_percentage`
- **Cost**: `.cost.total_cost_usd`
- **Duration**: `.cost.total_duration_ms`
- **Project Path**: `.workspace.project_dir`

The script includes formatting functions:
- `format_model()` - 10 char model name, right padded
- `format_percentage()` - 2 digit percentage with zero padding
- `format_duration()` - 4 digit minutes with zero padding
- `format_cost()` - 4 char cost display ($0.0 to $999)
- `format_tokens()` - 4 char token display (0.0K to 999K)
- `format_project_dir()` - Truncates from left if too long

Example customizations:

**Remove project path:**
```bash
echo "[${MODEL_FMT}]${PCT_FMT}/${DUR_FMT}/${COST_FMT}/${INPUT_FMT}/${OUTPUT_FMT}/${TOTAL_FMT}"
```

**Show only percentage and tokens:**
```bash
echo "[${MODEL_FMT}]${PCT_FMT}/${TOTAL_FMT}"
```

**Add custom labels:**
```bash
echo "[${MODEL_FMT}] ${PCT_FMT} context | ${DUR_FMT}m | ${COST_FMT} | ${TOTAL_FMT} tokens"
```

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
```sql
-- Total cost by developer
SELECT 
  developer,
  COUNT(*) as sessions,
  SUM(cost_usd) as total_cost
FROM sessions
GROUP BY developer;

-- Last 7 days activity
SELECT 
  DATE(created_at) as date,
  developer,
  COUNT(*) as sessions
FROM sessions
WHERE created_at > NOW() - INTERVAL '7 days'
GROUP BY date, developer
ORDER BY date DESC;
```

## Files Created
```
~/.claude/
├── settings.json                    # Claude Code configuration
├── .ccmetrics-config.json           # Credentials (chmod 600)
├── ccmetrics.log                    # Sync activity log
├── metrics_queue/                   # Retry queue for failed sends
│   └── [timestamp]_[uuid].json
├── metrics_cache/                   # Session data cache for SessionEnd
│   └── [session_id].json
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

# Verify Supabase connection (reads from config file)
SUPABASE_URL=$(jq -r '.supabase_url' ~/.claude/.ccmetrics-config.json)
SUPABASE_KEY=$(jq -r '.supabase_key' ~/.claude/.ccmetrics-config.json)
curl -X GET "${SUPABASE_URL}/rest/v1/sessions?limit=1" \
  -H "apikey: ${SUPABASE_KEY}"

# Check queue
ls ~/.claude/metrics_queue/
```

### Disable monitoring
```bash
# Remove hooks from settings
# Edit ~/.claude/settings.json and remove "hooks" section

# Or delete hook scripts
rm ~/.claude/hooks/send_claude_metrics.sh
rm ~/.claude/hooks/process_metrics_queue.sh
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
