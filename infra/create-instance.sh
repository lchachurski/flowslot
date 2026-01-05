#!/bin/bash
# Create EC2 On-Demand instance for flowslot
# Requires: aws sso login first

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../scripts/lib"

# --- Lockfile using mkdir for atomic locking (works on macOS & Linux) ---
LOCKDIR="/tmp/flowslot-create-instance.lock"

cleanup_lock() {
  rm -rf "$LOCKDIR"
}

if ! mkdir "$LOCKDIR" 2>/dev/null; then
  # Check if the lock is stale (PID no longer running)
  if [ -f "$LOCKDIR/pid" ]; then
    OLD_PID=$(cat "$LOCKDIR/pid" 2>/dev/null || echo "")
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
      echo "[ERROR] Another create-instance process is running (PID: $OLD_PID)" >&2
      echo "[ERROR] If stale, remove: rm -rf $LOCKDIR" >&2
      exit 1
    else
      # Stale lock - clean up and retry
      rm -rf "$LOCKDIR"
      mkdir "$LOCKDIR" || { echo "[ERROR] Could not acquire lock" >&2; exit 1; }
    fi
  else
    echo "[ERROR] Lock exists but no PID file. Remove: rm -rf $LOCKDIR" >&2
    exit 1
  fi
fi

# Write PID and set up cleanup
echo $$ > "$LOCKDIR/pid"
trap cleanup_lock EXIT INT TERM

# Source common functions if available
if [ -f "$LIB_DIR/common.sh" ]; then
  source "$LIB_DIR/common.sh"
else
  log_info() { echo "[INFO] $(date '+%H:%M:%S') $*"; }
  log_warn() { echo "[WARN] $(date '+%H:%M:%S') $*" >&2; }
  log_error() { echo "[ERROR] $(date '+%H:%M:%S') $*" >&2; }
  die() { log_error "$*"; exit 1; }
  success() { echo "✓ $*"; }
  require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
fi

# --- Constants ---
readonly REGION="${AWS_REGION:-eu-central-1}"
readonly AMI_ID="ami-01099d45fb386e13b"  # Ubuntu 22.04 LTS arm64 (eu-central-1)
readonly SECURITY_GROUP_NAME="flowslot-dev"
readonly VOLUME_SIZE_GB=100
readonly KEY_NAME="${AWS_KEY_NAME:-}"
readonly TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
readonly INSTANCE_TYPE="t4g.xlarge"  # 4 vCPU, 16 GB RAM, ARM64

show_help() {
  cat << 'EOF'
Usage: ./create-instance.sh

Creates an AWS EC2 On-Demand instance for flowslot development.

Prerequisites:
  - AWS CLI configured
  - Run 'aws sso login' first

Environment variables:
  AWS_REGION          Region (default: eu-central-1)
  AWS_KEY_NAME        SSH key pair name (optional but recommended)
  TAILSCALE_AUTH_KEY  Tailscale reusable auth key (required for auto-setup)

Instance: t4g.xlarge (4 vCPU, 16 GB) - ~$0.15/hr On-Demand
EOF
}

if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
  show_help
  exit 0
fi

require_cmd aws
require_cmd jq

log_info "=== Creating EC2 On-Demand instance ==="
log_info "Region: $REGION"
log_info "Instance type: $INSTANCE_TYPE"

# Check Tailscale auth key
if [ -z "$TAILSCALE_AUTH_KEY" ]; then
  log_warn "TAILSCALE_AUTH_KEY not set!"
  log_warn "Get one from: https://login.tailscale.com/admin/settings/keys"
  log_warn "Then: export TAILSCALE_AUTH_KEY=tskey-auth-xxx"
  echo ""
fi

# Check AWS auth
log_info "Checking AWS authentication..."
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  die "AWS not authenticated. Run 'aws sso login' first."
fi
log_info "  AWS authenticated ✓"

# Check for existing flowslot-dev instance (prevent duplicates)
log_info "Checking for existing flowslot instances..."
EXISTING=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=flowslot-dev" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING" ]; then
  log_error "A flowslot-dev instance already exists!"
  echo ""
  echo "Existing instances:"
  echo "$EXISTING" | while read -r id state; do
    echo "  $id ($state)"
  done
  echo ""
  echo "Options:"
  echo "  1. Use the existing instance"
  echo "  2. Terminate it first:"
  echo "     aws ec2 terminate-instances --instance-ids <id> --region $REGION"
  echo ""
  exit 1
fi
log_info "  No existing instances ✓"

# Security group
log_info "Checking security group..."
SG_ID=$(aws ec2 describe-security-groups \
  --group-names "$SECURITY_GROUP_NAME" \
  --region "$REGION" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "")

if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
  log_info "  Creating security group: $SECURITY_GROUP_NAME"
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SECURITY_GROUP_NAME" \
    --description "Flowslot development server" \
    --region "$REGION" \
    --query 'GroupId' \
    --output text)
  
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 \
    --region "$REGION" >/dev/null
  log_info "  Created: $SG_ID ✓"
else
  log_info "  Exists: $SG_ID ✓"
fi

# Prepare user-data
log_info "Preparing user-data script..."
USER_DATA_FILE="$SCRIPT_DIR/user-data.sh"
if [ ! -f "$USER_DATA_FILE" ]; then
  die "user-data.sh not found at $USER_DATA_FILE"
fi

if [ -n "$TAILSCALE_AUTH_KEY" ]; then
  USER_DATA=$(sed "s|%%TAILSCALE_AUTH_KEY%%|$TAILSCALE_AUTH_KEY|g" "$USER_DATA_FILE" | base64 -w0 2>/dev/null || sed "s|%%TAILSCALE_AUTH_KEY%%|$TAILSCALE_AUTH_KEY|g" "$USER_DATA_FILE" | base64)
else
  USER_DATA=$(cat "$USER_DATA_FILE" | base64 -w0 2>/dev/null || cat "$USER_DATA_FILE" | base64)
fi
log_info "  User-data prepared ✓"

# Build launch spec
log_info "Creating instance..."
LAUNCH_SPEC=$(jq -n \
  --arg ami "$AMI_ID" \
  --arg instance_type "$INSTANCE_TYPE" \
  --arg sg_id "$SG_ID" \
  --arg user_data "$USER_DATA" \
  --argjson volume_size "$VOLUME_SIZE_GB" \
  '{
    ImageId: $ami,
    InstanceType: $instance_type,
    SecurityGroupIds: [$sg_id],
    UserData: $user_data,
    BlockDeviceMappings: [{
      DeviceName: "/dev/sda1",
      Ebs: { VolumeSize: $volume_size, VolumeType: "gp3", DeleteOnTermination: true }
    }],
    TagSpecifications: [{
      ResourceType: "instance",
      Tags: [
        {Key: "Name", Value: "flowslot-dev"},
        {Key: "Project", Value: "flowslot"}
      ]
    }]
  }')

if [ -n "$KEY_NAME" ]; then
  LAUNCH_SPEC=$(echo "$LAUNCH_SPEC" | jq --arg key "$KEY_NAME" '. + {KeyName: $key}')
  log_info "  SSH key: $KEY_NAME"
fi

# Create instance
RUN_RESULT=$(aws ec2 run-instances \
  --cli-input-json "$LAUNCH_SPEC" \
  --region "$REGION" \
  --output json 2>&1) || true

if echo "$RUN_RESULT" | grep -qi "error\|exception"; then
  log_error "Failed to create instance:"
  echo "$RUN_RESULT"
  exit 1
fi

INSTANCE_ID=$(echo "$RUN_RESULT" | jq -r '.Instances[0].InstanceId' 2>/dev/null || echo "")
if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "null" ]; then
  log_error "Failed to extract instance ID:"
  echo "$RUN_RESULT"
  exit 1
fi

log_info "  Instance ID: $INSTANCE_ID ✓"

# Wait for running state with status updates
log_info "Waiting for instance to start..."
for i in {1..24}; do  # Max 2 minutes
  STATE=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "unknown")
  
  if [ "$STATE" = "running" ]; then
    log_info "  State: running ✓"
    break
  fi
  
  if [ $((i % 3)) -eq 0 ]; then
    log_info "  State: $STATE (waiting...)"
  fi
  sleep 5
done

# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

log_info "  Public IP: $PUBLIC_IP ✓"

# Wait for Tailscale with verbose status every 15 seconds
log_info ""
log_info "=== Waiting for cloud-init & Tailscale (up to 7 min) ==="
log_info ""

TAILSCALE_IP=""
START_TIME=$(date +%s)
MAX_WAIT=420  # 7 minutes

while true; do
  ELAPSED=$(($(date +%s) - START_TIME))
  
  if [ $ELAPSED -ge $MAX_WAIT ]; then
    log_warn "Timeout after 7 minutes"
    break
  fi
  
  # Try SSH to get Tailscale IP
  TAILSCALE_IP=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes "ubuntu@$PUBLIC_IP" "tailscale ip -4 2>/dev/null" 2>/dev/null || echo "")
  
  if [ -n "$TAILSCALE_IP" ]; then
    log_info "  Tailscale connected: $TAILSCALE_IP ✓"
    break
  fi
  
  # Status update every 15 seconds
  if [ $((ELAPSED % 15)) -lt 5 ]; then
    MINS=$((ELAPSED / 60))
    SECS=$((ELAPSED % 60))
    
    # Try to get cloud-init status
    CLOUD_STATUS=$(ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes "ubuntu@$PUBLIC_IP" "cloud-init status 2>/dev/null | head -1" 2>/dev/null || echo "connecting...")
    
    log_info "  [${MINS}m ${SECS}s] $CLOUD_STATUS"
  fi
  
  sleep 5
done

# Result
echo ""
if [ -n "$TAILSCALE_IP" ]; then
  success "Instance created successfully!"
else
  log_warn "Tailscale not ready yet. Check manually:"
  log_warn "  ssh ubuntu@$PUBLIC_IP 'tailscale ip -4'"
  log_warn "  ssh ubuntu@$PUBLIC_IP 'sudo cat /var/log/user-data.log'"
  TAILSCALE_IP="<pending>"
fi

echo ""
echo "============================================================"
echo "  NEXT STEPS"
echo "============================================================"
echo ""
echo "  1. Configure Tailscale Split DNS:"
echo "     https://login.tailscale.com/admin/dns"
echo "     Add nameserver: $TAILSCALE_IP → Restrict to: flowslot.dev"
echo ""
echo "  2. Update your .slotconfig:"
echo "     SLOT_REMOTE_HOST=\"ubuntu@$TAILSCALE_IP\""
echo "     SLOT_AWS_INSTANCE_ID=\"$INSTANCE_ID\""
echo ""
echo "============================================================"
