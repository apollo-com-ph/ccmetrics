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
  model TEXT,
  seven_day_utilization INTEGER,
  seven_day_resets_at TIMESTAMPTZ,
  five_hour_utilization INTEGER,
  five_hour_resets_at TIMESTAMPTZ,
  seven_day_sonnet_utilization INTEGER,
  seven_day_sonnet_resets_at TIMESTAMPTZ,
  claude_account_email TEXT
);

-- Create indexes for faster queries
CREATE INDEX idx_developer ON sessions(developer);
CREATE INDEX idx_created_at ON sessions(created_at);

-- Enable Row Level Security with write-only policy
-- This allows developers to submit metrics but not read/modify others' data
ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow insert for anon" ON sessions
  FOR INSERT
  TO anon
  WITH CHECK (true);
```

> **Security Note:** With RLS enabled and only an INSERT policy defined, developers with the publishable key can submit metrics but cannot SELECT, UPDATE, or DELETE any records. Admins can access all data via the Supabase dashboard or using the `service_role` key.

4. Click **Run** (or press Ctrl/Cmd + Enter)
5. Verify success message appears

### Option B: Using Table Editor (Manual)

1. Go to **Table Editor** in left sidebar
2. Click **New Table**
3. Configure:
   - **Name**: `sessions`
   - **Description**: "Claude Code session metadata"
   - **Enable RLS**: ON (recommended for security)

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
| model | text | - | Yes | No | No |
| seven_day_utilization | int4 | - | Yes | No | No |
| seven_day_resets_at | timestamptz | - | Yes | No | No |
| five_hour_utilization | int4 | - | Yes | No | No |
| five_hour_resets_at | timestamptz | - | Yes | No | No |
| seven_day_sonnet_utilization | int4 | - | Yes | No | No |
| seven_day_sonnet_resets_at | timestamptz | - | Yes | No | No |
| claude_account_email | text | - | Yes | No | No |

5. Click **Save**

6. **Create RLS Policy** (if RLS is enabled):
   - Go to **SQL Editor** → **New query**
   - Run:
   ```sql
   CREATE POLICY "Allow insert for anon" ON sessions
     FOR INSERT
     TO anon
     WITH CHECK (true);
   ```

**Note:** The `developer` field stores the work email address entered during setup. The `claude_account_email` field stores the actual Anthropic account email (fetched automatically from OAuth).

## Step 5: Get API Credentials

1. Go to **Settings** (gear icon) → **API**
2. Find these values:
```
Project URL: https://xxxxxxxxxxxxx.supabase.co
```

3. Under "Project API keys":
   - Copy **Publishable** key (starts with `sb_publishable_`) - preferred
   - Or legacy **`anon` public** key (starts with `eyJhbGc...`) - deprecated but still works
   - These keys are safe to use in hooks (have RLS restrictions if enabled)

4. **Save both values** - you'll need them for setup!

## Step 6: Test Connection

Test your setup (before running the install script):
```bash
# Replace with your values
SUPABASE_URL="https://xxxxxxxxxxxxx.supabase.co"
SUPABASE_KEY="eyJhbGc..."

# Test write access (should succeed)
curl -X POST "${SUPABASE_URL}/rest/v1/sessions" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=minimal" \
  -d '{
    "session_id": "test-123",
    "developer": "test@example.com",
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

# Test read access (should fail - RLS blocks reads)
curl -X GET "${SUPABASE_URL}/rest/v1/sessions?limit=1" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}"
# Should return: [] (empty array - no read access)

# Test delete access (should fail - RLS blocks deletes)
curl -X DELETE "${SUPABASE_URL}/rest/v1/sessions?session_id=eq.test-123" \
  -H "apikey: ${SUPABASE_KEY}" \
  -H "Authorization: Bearer ${SUPABASE_KEY}"
# Should return: HTTP 204 but no rows affected
```

After installation, credentials are stored in `~/.claude/.ccmetrics-config.json`:
```bash
# Read credentials from config file
SUPABASE_URL=$(jq -r '.supabase_url' ~/.claude/.ccmetrics-config.json)
SUPABASE_KEY=$(jq -r '.supabase_key' ~/.claude/.ccmetrics-config.json)
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

### "Row Level Security" errors on INSERT

If inserts are failing with RLS errors, verify the policy exists:
```sql
-- Check existing policies
SELECT * FROM pg_policies WHERE tablename = 'sessions';

-- If missing, create the write-only policy
CREATE POLICY "Allow insert for anon" ON sessions
  FOR INSERT
  TO anon
  WITH CHECK (true);
```

### Cannot read data with publishable key

This is expected behavior. With write-only RLS, the publishable key can only INSERT data. To read data:
- Use the **Supabase Dashboard** → Table Editor
- Use the `service_role` key (keep this secret, never distribute to developers)
- Query via SQL Editor in the dashboard

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
