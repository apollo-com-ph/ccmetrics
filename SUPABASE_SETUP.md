# Supabase Setup Guide

Complete guide to setting up Supabase for Claude Code metrics collection.

## Step 1: Create Supabase Account

1. Go to [supabase.com](https://supabase.com)
2. Click "Start your project"
3. Sign up with GitHub or email
4. Verify email (if using email signup)

## Step 2: Create Organization (Optional)

1. Click on your profile → Organizations
2. Create new organization: "Your Company Name"
3. Free tier selected ✓

## Step 3: Create Project

1. Click "New Project"
2. Fill in details:
   - **Name**: `claude-monitoring`
   - **Database Password**: [Generate strong password - SAVE THIS!]
   - **Region**: Choose closest to your team
   - **Pricing Plan**: Free ✓
3. Click "Create new project"
4. Wait 2-3 minutes for provisioning

## Step 4: Create Database Table

### Option A: Using SQL Editor (Recommended)

1. Go to **SQL Editor** in left sidebar
2. Click **New query**
3. Paste this SQL:
```sql
-- Create sessions table
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

-- Create indexes for faster queries
CREATE INDEX idx_developer ON sessions(developer);
CREATE INDEX idx_created_at ON sessions(created_at);

-- Disable Row Level Security (RLS) for simplicity
-- WARNING: Only do this if you trust all API key holders
ALTER TABLE sessions DISABLE ROW LEVEL SECURITY;
```

4. Click **Run** (or press Ctrl/Cmd + Enter)
5. Verify success message appears

### Option B: Using Table Editor (Manual)

1. Go to **Table Editor** in left sidebar
2. Click **New Table**
3. Configure:
   - **Name**: `sessions`
   - **Description**: "Claude Code session metadata"
   - Enable **Enable RLS**: OFF (for simplicity)

4. Add columns:

| Column Name | Type | Default | Nullable | Unique | Identity |
|------------|------|---------|----------|--------|----------|
| id | int8 | - | No | Yes | Yes (generated) |
| created_at | timestamptz | now() | No | No | No |
| session_id | text | - | No | No | No |
| developer | text | - | No | No | No |
| hostname | text | - | Yes | No | No |
| project_path | text | - | Yes | No | No |
| duration_minutes | numeric | - | Yes | No | No |
| cost_usd | numeric | - | Yes | No | No |
| input_tokens | int4 | - | Yes | No | No |
| output_tokens | int4 | - | Yes | No | No |
| message_count | int4 | - | Yes | No | No |
| user_message_count | int4 | - | Yes | No | No |
| tools_used | text | - | Yes | No | No |
| context_usage_percent | numeric | - | Yes | No | No |
| seven_day_utilization | int4 | - | Yes | No | No |
| seven_day_resets_at | timestamptz | - | Yes | No | No |

5. Click **Save**

## Step 5: Get API Credentials

1. Go to **Settings** (gear icon) → **API**
2. Find these values:
```
Project URL: https://xxxxxxxxxxxxx.supabase.co
```

3. Under "Project API keys":
   - Copy **`anon` public** key (starts with `eyJhbGc...`)
   - This is safe to use in hooks (has RLS restrictions if enabled)

4. **Save both values** - you'll need them for setup!

## Step 6: Test Connection

Test your setup:
```bash
# Replace with your values
SUPABASE_URL="https://xxxxxxxxxxxxx.supabase.co"
SUPABASE_KEY="eyJhbGc..."

# Test read access
curl -X GET "${SUPABASE_URL}/rest/v1/sessions?limit=1" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}"

# Should return: []

# Test write access
curl -X POST "${SUPABASE_URL}/rest/v1/sessions" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  -d '{
    "session_id": "test-123",
    "developer": "test_user",
    "hostname": "test-host",
    "project_path": "/test",
    "duration_minutes": 1.5,
    "cost_usd": 0.01,
    "input_tokens": 100,
    "output_tokens": 50,
    "message_count": 1,
    "user_message_count": 1,
    "tools_used": "test"
  }'

# Should return: HTTP 201 (success)
```

## Step 7: Verify Data

1. Go to **Table Editor** → **sessions**
2. You should see your test row
3. Delete test row (optional): Click row → Delete

## Step 8: Set Up Dashboards (Optional)

### Create Basic Views
```sql
-- Create view for daily summary
CREATE VIEW daily_summary AS
SELECT 
  DATE(created_at) as date,
  developer,
  COUNT(*) as session_count,
  SUM(cost_usd) as total_cost,
  SUM(duration_minutes) as total_duration
FROM sessions
GROUP BY DATE(created_at), developer
ORDER BY date DESC;

-- Create view for project breakdown
CREATE VIEW project_breakdown AS
SELECT
  developer,
  project_path,
  COUNT(*) as sessions,
  SUM(cost_usd) as cost,
  SUM(duration_minutes) as duration
FROM sessions
GROUP BY developer, project_path;
```

## Common Issues

### "Row Level Security" errors

If you get RLS errors:
```sql
ALTER TABLE sessions DISABLE ROW LEVEL SECURITY;
```

Or create policy:
```sql
-- Allow all operations for now (tighten later)
CREATE POLICY "Allow all" ON sessions
  FOR ALL
  USING (true)
  WITH CHECK (true);
```

### Connection refused

- Check Project URL is correct (include `https://`)
- Verify project is active (not paused)
- Check API key is the `anon` public key

### Invalid API key

- Make sure you copied the full key
- Check for extra spaces
- Verify you're using `anon` key, not `service_role`

## Next Steps

1. Run the setup script: `bash setup_ccmetrics.sh`
2. Enter your Supabase URL and API key
3. Start using Claude Code - data will flow automatically!

## Useful SQL Queries

See the [README.md](README.md#query-data-in-supabase) for example queries.
