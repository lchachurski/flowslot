#!/bin/bash
# Setup remote EC2 instance: Docker, Tailscale, idle-check cron
# Usage: ./setup-remote.sh <public-ip>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../scripts/lib"

# Source common functions if available
if [ -f "$LIB_DIR/common.sh" ]; then
  # shellcheck source=../scripts/lib/common.sh
  source "$LIB_DIR/common.sh"
else
  log_info() { echo "[INFO] $*"; }
  log_warn() { echo "[WARN] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
  die() { log_error "$*"; exit 1; }
  require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
fi

require_cmd ssh
require_cmd scp

if [ -z "${1:-}" ]; then
  die "Public IP required. Usage: ./setup-remote.sh <public-ip>"
fi

PUBLIC_IP="$1"
REMOTE_USER="${REMOTE_USER:-ubuntu}"

log_info "Setting up remote instance at $PUBLIC_IP..."
echo ""

# Test SSH connection
log_info "Testing SSH connection..."
if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$REMOTE_USER@$PUBLIC_IP" "echo 'SSH OK'" 2>/dev/null; then
  die "Cannot connect via SSH. Make sure:
  1. Instance is running
  2. Security group allows SSH (port 22)
  3. Your SSH key is configured"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Install Docker
log_info "Installing Docker..."
ssh "$REMOTE_USER@$PUBLIC_IP" bash << 'REMOTE_SCRIPT'
  set -e
  if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker $USER
  else
    echo "  Docker already installed"
  fi
REMOTE_SCRIPT

# Install Tailscale
log_info "Installing Tailscale..."
ssh "$REMOTE_USER@$PUBLIC_IP" bash << 'REMOTE_SCRIPT'
  set -e
  if ! command -v tailscale &> /dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
  else
    echo "  Tailscale already installed"
  fi
  
  # Start Tailscale (will prompt for auth)
  if ! tailscale status &>/dev/null; then
    echo ""
    echo "Tailscale needs to be authenticated."
    echo "Run this command on the remote server:"
    echo "  sudo tailscale up"
    echo ""
    echo "Or run it now (will open browser):"
    read -p "Press Enter to continue..."
    sudo tailscale up
  fi
REMOTE_SCRIPT

# Get Tailscale IP
echo ""
log_info "Getting Tailscale IP..."
TAILSCALE_IP=$(ssh "$REMOTE_USER@$PUBLIC_IP" "tailscale ip -4" 2>/dev/null | head -1 || echo "")

if [ -z "$TAILSCALE_IP" ]; then
  log_warn "Tailscale not connected. Run 'sudo tailscale up' on the remote server."
else
  echo "  Tailscale IP: $TAILSCALE_IP"
fi

# Deploy idle-check script
echo ""
log_info "Deploying idle-check script..."
scp "$SCRIPT_DIR/idle-check.sh" "$REMOTE_USER@$PUBLIC_IP:/tmp/idle-check.sh"
ssh "$REMOTE_USER@$PUBLIC_IP" bash << 'REMOTE_SCRIPT'
  sudo mv /tmp/idle-check.sh /usr/local/bin/flowslot-idle-check
  sudo chmod +x /usr/local/bin/flowslot-idle-check
REMOTE_SCRIPT

# Setup cron job
log_info "Setting up cron job (checks every 15 minutes)..."
ssh "$REMOTE_USER@$PUBLIC_IP" bash << 'REMOTE_SCRIPT'
  # Remove existing cron job if present
  crontab -l 2>/dev/null | grep -v "flowslot-idle-check" | crontab - 2>/dev/null || true
  
  # Add new cron job
  (crontab -l 2>/dev/null; echo "*/15 * * * * /usr/local/bin/flowslot-idle-check") | crontab -
REMOTE_SCRIPT

echo ""
success "Remote setup complete!"
echo ""
echo "Tailscale IP: ${TAILSCALE_IP:-not connected}"
echo ""
echo "Next steps:"
echo "  1. If Tailscale not connected, SSH and run: sudo tailscale up"
echo "  2. Lock down security group (remove public SSH access)"
echo "  3. Use Tailscale IP for remote host in 'slot init'"

