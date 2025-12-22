#!/bin/bash
# Idle check script - runs on remote EC2 via cron
# Stops instance if no containers running AND no SSH activity for 1 hour
#
# Install location: /usr/local/bin/flowslot-idle-check
# Cron: */15 * * * * /usr/local/bin/flowslot-idle-check

set -euo pipefail

readonly IDLE_LIMIT=3600  # 1 hour in seconds

# Check if any containers are running
CONTAINERS=$(docker ps -q 2>/dev/null | wc -l || echo 0)

if [[ "$CONTAINERS" -gt 0 ]]; then
  exit 0  # Not idle, containers running
fi

# Check last SSH activity
# Use auth.log or lastlog (Linux-specific)
LAST_AUTH=0
if [[ -f /var/log/auth.log ]]; then
  LAST_AUTH=$(stat -c %Y /var/log/auth.log 2>/dev/null || echo 0)
elif command -v last >/dev/null 2>&1; then
  # Fallback: use 'last' command to get last login time
  LAST_LOGIN=$(last -1 -R 2>/dev/null | head -1 | grep -v "wtmp" || echo "")
  if [[ -n "$LAST_LOGIN" ]]; then
    # If there's recent activity, use current time (not idle)
    LAST_AUTH=$(date +%s)
  fi
fi

NOW=$(date +%s)
IDLE_TIME=$((NOW - LAST_AUTH))

if [[ "$IDLE_TIME" -gt "$IDLE_LIMIT" ]]; then
  logger "flowslot: Idle for ${IDLE_TIME}s (limit: ${IDLE_LIMIT}s), stopping instance"
  sudo shutdown -h now
fi
