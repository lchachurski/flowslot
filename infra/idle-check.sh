#!/bin/bash
# Idle check script - runs on remote EC2 via cron
# Stops instance if no containers running AND no SSH activity for 1 hour

set -euo pipefail

readonly IDLE_LIMIT=3600  # 1 hour in seconds

# Check if any containers are running
CONTAINERS=$(docker ps -q 2>/dev/null | wc -l || echo 0)

if [ "$CONTAINERS" -gt 0 ]; then
  exit 0  # Not idle, containers running
fi

# Check last SSH activity
# Use lastlog or auth.log (Linux-specific)
if [ -f /var/log/auth.log ]; then
  LAST_AUTH=$(stat -c %Y /var/log/auth.log 2>/dev/null || echo 0)
elif command -v lastlog >/dev/null 2>&1; then
  # Fallback: use lastlog if available
  LAST_AUTH=$(lastlog -u "$(whoami)" 2>/dev/null | tail -1 | awk '{print $NF}' || echo 0)
else
  LAST_AUTH=0
fi

NOW=$(date +%s)
IDLE_TIME=$((NOW - LAST_AUTH))

if [ $IDLE_TIME -gt $IDLE_LIMIT ]; then
  logger "flowslot: Idle for ${IDLE_TIME}s, stopping instance"
  sudo shutdown -h now
fi

