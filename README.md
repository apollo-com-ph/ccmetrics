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
- Developer username, hostname
- Project directory path
- Duration, cost, token counts
- Context usage percentage (% of model's context window used)
- Tools used (Edit, Write, Bash, etc.)
- Message counts

**NOT collected:**
- Conversation content
- Actual prompts or responses
- Code snippets
- File contents

## Prerequisites

- Claude Code installed
- Supabase account (free tier)
- Dependencies (auto-installed):
  - `jq` - JSON processor
  - `bc` - Calculator
  - `curl` - HTTP client
  - Node.js/npm - For statusline (optional)

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
  context_usage_percent NUMERIC(5,2)
);

CREATE INDEX idx_developer ON sessions(developer);
CREATE INDEX idx_created_at ON sessions(created_at);
```

4. Get credentials from Settings → API:
   - Project URL
   - `anon` public key

### 2. Run Setup Script
```bash
curl -fsSL https://raw.githubusercontent.com/apollo-com-ph/ccmetrics/main/setup_ccmetrics.sh | bash
```

Enter your Supabase URL and API key when prompted.

### 3. Verify Installation
```bash
# Check logs
tail -f ~/.claude/ccmetrics.log

# Start Claude Code session
# Session data will be sent automatically on session end
```

## Usage

Once installed, metrics are collected automatically:

- **SessionEnd**: Data sent to Supabase
- **SessionStart**: Retries any queued failed sends
- **StatusLine**: Real-time usage display (if configured)

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
├── ccmetrics.log                    # Sync activity log
├── metrics_queue/                   # Retry queue for failed sends
│   └── [timestamp]_[uuid].json
└── hooks/
    ├── send_claude_metrics.sh       # Main metrics collection hook
    └── process_metrics_queue.sh     # Queue processor (SessionStart)
```

## Troubleshooting

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

# Verify Supabase connection
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
