#!/bin/bash
# Create EC2 Spot instance for flowslot
# Requires: aws sso login first

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../scripts/lib"

# --- Lockfile to prevent multiple instances ---
LOCKFILE="/tmp/flowslot-create-instance.lock"

acquire_lock() {
  if [ -f "$LOCKFILE" ]; then
    EXISTING_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
    if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
      echo "[ERROR] Another create-instance process is running (PID: $EXISTING_PID)" >&2
      echo "[ERROR] If this is stale, remove: $LOCKFILE" >&2
      exit 1
    else
      # Stale lockfile - remove it
      rm -f "$LOCKFILE"
    fi
  fi
  echo $$ > "$LOCKFILE"
}

release_lock() {
  rm -f "$LOCKFILE"
}

# Acquire lock and setup cleanup on exit
acquire_lock
trap release_lock EXIT INT TERM

# Source common functions if available
if [ -f "$LIB_DIR/common.sh" ]; then
  # shellcheck source=../scripts/lib/common.sh
  source "$LIB_DIR/common.sh"
else
  # Fallback if common.sh not found
  log_info() { echo "[INFO] $*"; }
  log_warn() { echo "[WARN] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
  die() { log_error "$*"; exit 1; }
  success() { echo "✓ $*"; }
  require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
fi

# --- Constants ---
readonly REGION="${AWS_REGION:-eu-central-1}"
readonly AMI_ID="ami-01099d45fb386e13b"  # Ubuntu 22.04 LTS arm64 (eu-central-1)
readonly SECURITY_GROUP_NAME="flowslot-dev"
readonly VOLUME_SIZE_GB=100
readonly KEY_NAME="${AWS_KEY_NAME:-}"  # Set your key name or leave empty
readonly TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"  # Tailscale reusable auth key

# Instance types to try in order of preference (all ARM64, 16GB+ RAM)
# Priority: more resources first, all meet minimum 16GB RAM requirement
readonly INSTANCE_TYPES=("t4g.2xlarge" "t4g.xlarge" "m6g.xlarge" "r6g.large")
#                        8 vCPU/32GB   4 vCPU/16GB  4 vCPU/16GB  2 vCPU/16GB

show_help() {
  cat << 'EOF'
Usage: ./create-instance.sh

Creates an AWS EC2 Spot instance for flowslot development.

Prerequisites:
  - AWS CLI configured
  - Run 'aws sso login' first

Environment variables:
  AWS_REGION          Region to create instance in (default: eu-central-1)
  AWS_KEY_NAME        SSH key pair name (optional)
  TAILSCALE_AUTH_KEY  Tailscale reusable auth key (required for auto-setup)

Options:
  -h, --help     Show this help message

Instance types (tried in order):
  1. t4g.2xlarge (8 vCPU, 32 GB) - preferred
  2. t4g.xlarge  (4 vCPU, 16 GB) - fallback 1
  3. m6g.xlarge  (4 vCPU, 16 GB) - fallback 2
  4. r6g.large   (2 vCPU, 16 GB) - fallback 3

Notes:
  - Only one instance can be created at a time (lockfile: /tmp/flowslot-create-instance.lock)
  - Script waits up to 7 minutes for Tailscale to connect
  - If Spot capacity is unavailable, script tries fallback instance types
  - Minimum 16GB RAM is maintained for all fallback options
  - If lockfile is stale, remove it manually
EOF
}

# Parse arguments
if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
  show_help
  exit 0
fi

require_cmd aws
require_cmd jq
require_cmd base64

log_info "Creating EC2 Spot instance in $REGION..."

# Check for Tailscale auth key
if [ -z "$TAILSCALE_AUTH_KEY" ]; then
  log_warn "TAILSCALE_AUTH_KEY not set. Instance will be created but Tailscale won't auto-connect."
  log_warn "Get a reusable auth key from: https://login.tailscale.com/admin/settings/keys"
  log_warn "Then run: export TAILSCALE_AUTH_KEY=tskey-auth-xxx"
fi

# Check AWS authentication
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  die "AWS not authenticated. Run 'aws sso login' first."
fi

# Create security group if it doesn't exist
SG_ID=$(aws ec2 describe-security-groups \
  --group-names "$SECURITY_GROUP_NAME" \
  --region "$REGION" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || echo "")

if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
  log_info "Creating security group: $SECURITY_GROUP_NAME"
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SECURITY_GROUP_NAME" \
    --description "Flowslot development server" \
    --region "$REGION" \
    --query 'GroupId' \
    --output text)
  
  # Allow SSH temporarily (will be locked down after Tailscale setup)
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 \
    --region "$REGION" >/dev/null
  
  log_info "  Created: $SG_ID"
else
  log_info "Security group exists: $SG_ID"
fi

# Prepare user-data script
USER_DATA_FILE="$SCRIPT_DIR/user-data.sh"
if [ ! -f "$USER_DATA_FILE" ]; then
  die "user-data.sh not found at $USER_DATA_FILE"
fi

# Substitute TAILSCALE_AUTH_KEY placeholder in user-data and base64 encode
# Use %% as delimiter to avoid conflicts with / in keys
if [ -n "$TAILSCALE_AUTH_KEY" ]; then
  USER_DATA=$(sed "s|%%TAILSCALE_AUTH_KEY%%|$TAILSCALE_AUTH_KEY|g" "$USER_DATA_FILE" | base64 -w0)
else
  # Still pass user-data but leave placeholder as-is (script will detect and warn)
  USER_DATA=$(cat "$USER_DATA_FILE" | base64 -w0)
fi

# Try each instance type until one succeeds
INSTANCE_ID=""
SELECTED_TYPE=""

for INSTANCE_TYPE in "${INSTANCE_TYPES[@]}"; do
  log_info "Trying Spot instance: $INSTANCE_TYPE..."
  
  # Build launch specification using jq for proper JSON
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
        Ebs: {
          VolumeSize: $volume_size,
          VolumeType: "gp3",
          DeleteOnTermination: true
        }
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
  fi

  # Try to create the instance
  RUN_RESULT=$(aws ec2 run-instances \
    --cli-input-json "$LAUNCH_SPEC" \
    --instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"persistent","InstanceInterruptionBehavior":"stop"}}' \
    --region "$REGION" \
    --output json 2>&1) || true
  
  # Check for capacity errors
  if echo "$RUN_RESULT" | grep -q "InsufficientInstanceCapacity\|SpotMaxPriceTooLow\|InsufficientFreeAddressesInSubnet"; then
    log_warn "No Spot capacity for $INSTANCE_TYPE, trying next..."
    continue
  fi
  
  # Check for other errors
  if echo "$RUN_RESULT" | grep -qi "error\|exception"; then
    log_error "Failed to create $INSTANCE_TYPE:"
    echo "$RUN_RESULT" | head -5
    continue
  fi
  
  # Success - extract instance ID
  INSTANCE_ID=$(echo "$RUN_RESULT" | jq -r '.Instances[0].InstanceId' 2>/dev/null || echo "")
  
  if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "null" ]; then
    SELECTED_TYPE="$INSTANCE_TYPE"
    break
  fi
done

# Check if any instance was created
if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "null" ]; then
  log_error "Failed to create instance. No Spot capacity available for any instance type."
  echo ""
  echo "Tried: ${INSTANCE_TYPES[*]}"
  echo ""
  echo "Options:"
  echo "  1. Try again later — Spot capacity fluctuates"
  echo "  2. Try a different region — set AWS_REGION environment variable"
  echo "  3. Check AWS Spot pricing and capacity dashboard"
  exit 1
fi

log_info "  Instance type: $SELECTED_TYPE"
log_info "  Instance ID: $INSTANCE_ID"
log_info "Waiting for instance to be running..."

aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION"

# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

success "Instance created successfully!"
log_info "Instance ID: $INSTANCE_ID"
log_info "Public IP: $PUBLIC_IP"
log_info "Region: $REGION"
log_info ""

# Wait for cloud-init and Tailscale to complete
log_info "Waiting for cloud-init to complete and Tailscale to connect..."
log_info "(this takes 4-6 minutes, max wait: 7 minutes)"
echo ""

TAILSCALE_IP=""
MAX_ATTEMPTS=84  # 7 minutes max (84 * 5s = 420s)
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  ATTEMPT=$((ATTEMPT + 1))
  
  # Try to get Tailscale IP via SSH
  TAILSCALE_IP=$(ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes "ubuntu@$PUBLIC_IP" "tailscale ip -4 2>/dev/null" 2>/dev/null || echo "")
  
  if [ -n "$TAILSCALE_IP" ]; then
    echo ""
    break
  fi
  
  # Show progress every 10 seconds
  if [ $((ATTEMPT % 2)) -eq 0 ]; then
    echo -n "."
  fi
  
  sleep 5
done

if [ -z "$TAILSCALE_IP" ]; then
  echo ""
  log_warn "Could not get Tailscale IP after 7 minutes."
  log_warn "Instance may still be initializing. Check manually:"
  log_warn "  ssh ubuntu@$PUBLIC_IP 'tailscale ip -4'"
  log_warn "  ssh ubuntu@$PUBLIC_IP 'sudo cat /var/log/user-data.log'"
  log_warn ""
  log_warn "NOT locking down SSH - you need to do it manually after getting Tailscale IP:"
  log_warn "  aws ec2 revoke-security-group-ingress --group-name $SECURITY_GROUP_NAME --protocol tcp --port 22 --cidr 0.0.0.0/0 --region $REGION"
  TAILSCALE_IP="<pending - check manually>"
  SSH_LOCKED=false
else
  SSH_LOCKED=true
fi

log_info "Tailscale IP: $TAILSCALE_IP"
log_info ""

# Only lock down security group if we got Tailscale IP
if [ "$SSH_LOCKED" = true ]; then
  log_info "Locking down security group (removing public SSH)..."
  aws ec2 revoke-security-group-ingress \
    --group-name "$SECURITY_GROUP_NAME" \
    --protocol tcp --port 22 --cidr 0.0.0.0/0 \
    --region "$REGION" 2>/dev/null || log_warn "SSH rule already removed or doesn't exist"
  success "Public SSH access removed. Access now via Tailscale only."
  log_info ""
fi

echo ""
echo "============================================================"
echo "  ACTION REQUIRED: Configure Tailscale Split DNS"
echo "============================================================"
echo ""
echo "  1. Go to: https://login.tailscale.com/admin/dns"
echo ""
echo "  2. Under 'Nameservers', click 'Add nameserver' → 'Custom'"
echo ""
echo "  3. Enter these values:"
echo "     ┌─────────────────────────────────────────────┐"
echo "     │  Nameserver:  $TAILSCALE_IP"
echo "     │  Restrict to: flowslot.dev"
echo "     └─────────────────────────────────────────────┘"
echo ""
echo "  4. Click 'Save'"
echo ""
echo "  5. Test DNS resolution:"
echo "     dig test.flowslot.dev +short"
echo "     # Expected output: $TAILSCALE_IP"
echo ""
echo "  Without this, *.flowslot.dev domains won't resolve!"
echo "============================================================"
echo ""
echo "Update your project's .slotconfig with:"
echo "  SLOT_REMOTE_HOST=\"ubuntu@$TAILSCALE_IP\""
echo "  SLOT_AWS_INSTANCE_ID=\"$INSTANCE_ID\""
echo ""
