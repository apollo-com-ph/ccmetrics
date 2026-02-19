#!/bin/bash
set -euo pipefail

# This hook runs on SessionStart to retry failed metrics
export HOOK_EVENT="SessionStart"

# Call the main metrics script to process queue
~/.claude/hooks/send_claude_metrics.sh < /dev/null

exit 0
