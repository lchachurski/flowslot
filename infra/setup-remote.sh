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
  success() { echo "✓ $*"; }
  require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
fi

show_help() {
  cat << 'EOF'
Usage: ./setup-remote.sh <public-ip>

Sets up a remote EC2 instance with Docker, Tailscale, and idle-check cron.

Arguments:
  public-ip      The public IP address of the EC2 instance

Environment variables:
  REMOTE_USER    SSH user (default: ubuntu)

Options:
  -h, --help     Show this help message

After running this script, you must manually authenticate Tailscale:
  ssh ubuntu@<public-ip> 'sudo tailscale up'
EOF
}

# Parse arguments
if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
  show_help
  exit 0
fi

require_cmd ssh
require_cmd scp

if [ -z "${1:-}" ]; then
  die "Public IP required. Usage: ./setup-remote.sh <public-ip>"
fi

PUBLIC_IP="$1"
REMOTE_USER="${REMOTE_USER:-ubuntu}"

log_info "Setting up remote instance at $PUBLIC_IP..."

# Test SSH connection
log_info "Testing SSH connection..."
if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$REMOTE_USER@$PUBLIC_IP" "echo 'SSH OK'" 2>/dev/null; then
  die "Cannot connect via SSH. Make sure:
  1. Instance is running
  2. Security group allows SSH (port 22)
  3. Your SSH key is configured"
fi

# Install Docker
log_info "Installing Docker..."
ssh "$REMOTE_USER@$PUBLIC_IP" bash << 'REMOTE_SCRIPT'
  set -euo pipefail
  if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    echo "  Docker installed"
  else
    echo "  Docker already installed"
  fi
REMOTE_SCRIPT

# Install Tailscale
log_info "Installing Tailscale..."
ssh "$REMOTE_USER@$PUBLIC_IP" bash << 'REMOTE_SCRIPT'
  set -euo pipefail
  if ! command -v tailscale &> /dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "  Tailscale installed"
  else
    echo "  Tailscale already installed"
  fi
REMOTE_SCRIPT

# Check Tailscale status
log_info "Checking Tailscale status..."
TAILSCALE_IP=$(ssh "$REMOTE_USER@$PUBLIC_IP" "tailscale ip -4 2>/dev/null" | head -1 || echo "")

if [ -z "$TAILSCALE_IP" ]; then
  log_warn "Tailscale not connected."
  log_warn "You must manually authenticate by running:"
  log_warn "  ssh $REMOTE_USER@$PUBLIC_IP 'sudo tailscale up'"
else
  log_info "  Tailscale IP: $TAILSCALE_IP"
fi

# Deploy idle-check script
log_info "Deploying idle-check script..."
scp "$SCRIPT_DIR/idle-check.sh" "$REMOTE_USER@$PUBLIC_IP:/tmp/idle-check.sh"
ssh "$REMOTE_USER@$PUBLIC_IP" bash << 'REMOTE_SCRIPT'
  set -euo pipefail
  sudo mv /tmp/idle-check.sh /usr/local/bin/flowslot-idle-check
  sudo chmod +x /usr/local/bin/flowslot-idle-check
  echo "  Deployed to /usr/local/bin/flowslot-idle-check"
REMOTE_SCRIPT

# Setup cron job
log_info "Setting up cron job (checks every 15 minutes)..."
ssh "$REMOTE_USER@$PUBLIC_IP" bash << 'REMOTE_SCRIPT'
  set -euo pipefail
  # Remove existing cron job if present
  crontab -l 2>/dev/null | grep -v "flowslot-idle-check" | crontab - 2>/dev/null || true
  
  # Add new cron job
  (crontab -l 2>/dev/null; echo "*/15 * * * * /usr/local/bin/flowslot-idle-check") | crontab -
  echo "  Cron job configured"
REMOTE_SCRIPT

# Lock down security group if Tailscale is working
if [ -n "$TAILSCALE_IP" ]; then
  log_info "Verifying Tailscale SSH access..."
  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$REMOTE_USER@$TAILSCALE_IP" "echo 'Tailscale SSH OK'" 2>/dev/null; then
    log_info "  Tailscale SSH works!"
    
    log_info "Locking down security group (removing public SSH)..."
    if aws ec2 revoke-security-group-ingress \
      --group-name flowslot-dev \
      --protocol tcp --port 22 --cidr 0.0.0.0/0 \
      --region "${AWS_REGION:-eu-central-1}" 2>/dev/null; then
      log_info "  Public SSH access removed"
    else
      log_warn "  Could not remove SSH rule (may already be removed)"
    fi
  else
    log_warn "  Tailscale SSH not working. Keeping public SSH open for now."
  fi
fi

success "Remote setup complete!"
log_info "Tailscale IP: ${TAILSCALE_IP:-not connected}"
log_info ""
if [ -z "$TAILSCALE_IP" ]; then
  log_info "Next steps:"
  log_info "  1. Authenticate Tailscale:"
  log_info "     ssh $REMOTE_USER@$PUBLIC_IP 'sudo tailscale up'"
  log_info "  2. Run this script again to lock down security group"
  log_info "  3. Use Tailscale IP for remote host in 'slot init'"
else
  log_info "Access only via Tailscale: $TAILSCALE_IP"
fi
