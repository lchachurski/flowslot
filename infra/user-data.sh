#!/bin/bash
# EC2 User Data - runs on first boot via cloud-init
# This script bootstraps the entire flowslot infrastructure:
# - Docker installation
# - Tailscale setup with auth key
# - dnsmasq wildcard DNS configuration
# - Idle-check script deployment
#
# Requires: TAILSCALE_AUTH_KEY environment variable (set in create-instance.sh)

set -euo pipefail

# Log everything to cloud-init output
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "=== Flowslot EC2 Bootstrap Started ==="
date

# Install Docker
echo "Installing Docker..."
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | sh
  usermod -aG docker ubuntu
  echo "Docker installed"
else
  echo "Docker already installed"
fi

# Install Tailscale
echo "Installing Tailscale..."
if ! command -v tailscale &> /dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
  echo "Tailscale installed"
else
  echo "Tailscale already installed"
fi

# Authenticate Tailscale with auth key
echo "Authenticating Tailscale..."
if [ -z "${TAILSCALE_AUTH_KEY:-}" ]; then
  echo "WARNING: TAILSCALE_AUTH_KEY not set. Tailscale will not auto-connect."
  echo "Run 'sudo tailscale up' manually after instance starts."
else
  tailscale up --authkey="${TAILSCALE_AUTH_KEY}" --ssh --accept-routes || {
    echo "WARNING: Tailscale authentication failed. Check auth key."
  }
fi

# Wait for Tailscale to get an IP (up to 30 seconds)
echo "Waiting for Tailscale IP..."
for i in {1..30}; do
  TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
  if [ -n "$TS_IP" ]; then
    echo "Tailscale IP: $TS_IP"
    break
  fi
  sleep 1
done

if [ -z "${TS_IP:-}" ]; then
  echo "WARNING: Could not get Tailscale IP. dnsmasq config may fail."
  TS_IP="100.0.0.0"  # Placeholder, will need manual fix
fi

# Disable systemd-resolved (port 53 conflict)
echo "Disabling systemd-resolved..."
systemctl stop systemd-resolved || true
systemctl disable systemd-resolved || true
if [ -L /etc/resolv.conf ]; then
  rm /etc/resolv.conf
fi
if [ ! -f /etc/resolv.conf ]; then
  echo "nameserver 127.0.0.1" > /etc/resolv.conf
fi

# Install dnsmasq
echo "Installing dnsmasq..."
apt-get update -qq
apt-get install -y dnsmasq

# Write dnsmasq config with Tailscale IP
echo "Configuring dnsmasq..."
cat > /etc/dnsmasq.d/flowslot.conf << EOF
# Flowslot wildcard DNS configuration
# Wildcard: *.flowslot -> Tailscale IP
address=/flowslot/${TS_IP}

# Listen on Tailscale and localhost
listen-address=${TS_IP}
listen-address=127.0.0.1

# Don't read /etc/resolv.conf (avoid loops)
no-resolv

# Upstream DNS for other queries
server=8.8.8.8
server=1.1.1.1

# Bind to specific interfaces only
bind-interfaces
EOF

# dnsmasq systemd dependency on Tailscale
echo "Configuring dnsmasq systemd dependency..."
mkdir -p /etc/systemd/system/dnsmasq.service.d
cat > /etc/systemd/system/dnsmasq.service.d/tailscale.conf << 'SYSTEMD_EOF'
[Unit]
After=tailscaled.service
Wants=tailscaled.service
SYSTEMD_EOF

systemctl daemon-reload
systemctl enable dnsmasq
systemctl restart dnsmasq || {
  echo "WARNING: dnsmasq restart failed. Check logs: journalctl -u dnsmasq"
}

# Deploy idle-check script
echo "Deploying idle-check script..."
cat > /usr/local/bin/flowslot-idle-check << 'IDLE_SCRIPT'
#!/bin/bash
# Idle check script - runs on remote EC2 via cron
# Stops instance after 2 hours of inactivity (no file changes, no requests)
#
# Install location: /usr/local/bin/flowslot-idle-check
# Cron: */5 * * * * /usr/local/bin/flowslot-idle-check

set -euo pipefail

readonly IDLE_LIMIT=7200  # 2 hours in seconds
readonly STATE_FILE="/tmp/flowslot-last-activity"
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

# Check 2: Docker container CPU activity (indicates requests/processing)
check_docker_activity() {
  # Check if any container has significant CPU usage (> 5%)
  # Note: Postgres idles at ~2% due to background tasks, so 5% threshold avoids false positives
  ACTIVE_CONTAINERS=$(docker stats --no-stream --format "{{.CPUPerc}}" 2>/dev/null | \
    sed 's/%//g' | \
    awk '$1 > 5.0 {count++} END {print count+0}')
  
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
IDLE_SCRIPT

chmod +x /usr/local/bin/flowslot-idle-check

# Setup cron job
echo "Setting up cron job..."
(crontab -l 2>/dev/null | grep -v "flowslot-idle-check" || true) | crontab -
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/flowslot-idle-check") | crontab -

# Create slots directory
echo "Creating slots directory..."
mkdir -p /srv
chown ubuntu:ubuntu /srv

echo "=== Flowslot EC2 Bootstrap Complete ==="
date

# Output Tailscale IP for reference
echo ""
echo "Tailscale IP: ${TS_IP:-not available}"
echo "dnsmasq configured for *.flowslot -> ${TS_IP:-not available}"
echo ""
echo "Next steps:"
echo "1. Configure Tailscale Split DNS:"
echo "   - Go to https://login.tailscale.com/admin/dns"
echo "   - Add nameserver: ${TS_IP:-<tailscale-ip>}"
echo "   - Restrict to domain: flowslot"
echo "2. Test DNS: dig web.spider-seo.thunder.flowslot +short"

