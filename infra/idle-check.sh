#!/bin/bash
# Idle check script - runs on remote EC2 via cron
# Stops instance after 2 hours of inactivity (no file changes, no requests)
#
# Install location: /usr/local/bin/flowslot-idle-check
# Cron: */5 * * * * /usr/local/bin/flowslot-idle-check

set -euo pipefail

readonly IDLE_LIMIT=7200  # 2 hours in seconds
readonly STATE_FILE="/var/run/flowslot-last-activity"
readonly SLOTS_BASE="/srv"

# Initialize state file if it doesn't exist
if [[ ! -f "$STATE_FILE" ]]; then
  date +%s > "$STATE_FILE"
fi

# Function to update last activity timestamp
update_activity() {
  date +%s > "$STATE_FILE"
  logger "flowslot: Activity detected - $1"
}

# Check 1: Recent file changes in any slot directory (Mutagen syncs)
check_file_changes() {
  # Find files modified in last 5 minutes across all project directories
  for project_dir in "$SLOTS_BASE"/*/; do
    if [[ -d "$project_dir" ]]; then
      # Exclude common non-activity directories
      RECENT_FILES=$(find "$project_dir" -type f -mmin -5 \
        ! -path "*/node_modules/*" \
        ! -path "*/.git/*" \
        ! -path "*/.next/*" \
        ! -path "*/dist/*" \
        ! -name "*.log" \
        2>/dev/null | head -1)
      
      if [[ -n "$RECENT_FILES" ]]; then
        return 0  # Activity found
      fi
    fi
  done
  return 1  # No activity
}

# Check 2: Docker container network activity (requests coming in)
check_docker_activity() {
  # Check if any container has received network traffic recently
  # by looking at container stats - if CPU > 0.5% there's likely activity
  ACTIVE_CONTAINERS=$(docker stats --no-stream --format "{{.CPUPerc}}" 2>/dev/null | \
    sed 's/%//g' | \
    awk '$1 > 0.5 {count++} END {print count+0}')
  
  if [[ "$ACTIVE_CONTAINERS" -gt 0 ]]; then
    return 0  # Activity found
  fi
  return 1  # No activity
}

# Check 3: SSH/Tailscale connections
check_ssh_activity() {
  # Check for active SSH sessions
  ACTIVE_SSH=$(who 2>/dev/null | wc -l)
  if [[ "$ACTIVE_SSH" -gt 0 ]]; then
    return 0  # Active session
  fi
  
  # Check if auth.log was modified recently (within 5 mins)
  if [[ -f /var/log/auth.log ]]; then
    LAST_AUTH=$(stat -c %Y /var/log/auth.log 2>/dev/null || echo 0)
    NOW=$(date +%s)
    if [[ $((NOW - LAST_AUTH)) -lt 300 ]]; then
      return 0  # Recent auth activity
    fi
  fi
  
  return 1  # No activity
}

# Main activity check
ACTIVITY_DETECTED=false

if check_file_changes; then
  update_activity "file changes detected"
  ACTIVITY_DETECTED=true
elif check_docker_activity; then
  update_activity "container CPU activity"
  ACTIVITY_DETECTED=true
elif check_ssh_activity; then
  update_activity "SSH session active"
  ACTIVITY_DETECTED=true
fi

# If activity detected, we're done
if [[ "$ACTIVITY_DETECTED" == "true" ]]; then
  exit 0
fi

# No activity - check how long we've been idle
LAST_ACTIVITY=$(cat "$STATE_FILE" 2>/dev/null || date +%s)
NOW=$(date +%s)
IDLE_TIME=$((NOW - LAST_ACTIVITY))

logger "flowslot: No activity detected. Idle for ${IDLE_TIME}s (limit: ${IDLE_LIMIT}s)"

if [[ "$IDLE_TIME" -gt "$IDLE_LIMIT" ]]; then
  logger "flowslot: Idle limit exceeded. Stopping all containers and shutting down..."
  
  # Stop all Docker containers gracefully
  docker stop $(docker ps -q) 2>/dev/null || true
  
  # Give containers time to stop
  sleep 10
  
  # Shutdown the instance
  sudo shutdown -h now
fi
