#!/bin/bash
# Create EC2 Spot instance for flowslot
# Requires: aws sso login first

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../scripts/lib"

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
readonly INSTANCE_TYPE="t4g.2xlarge"  # ARM64, cheaper than t3
readonly AMI_ID="ami-01099d45fb386e13b"  # Ubuntu 22.04 LTS arm64 (eu-central-1)
readonly SECURITY_GROUP_NAME="flowslot-dev"
readonly VOLUME_SIZE_GB=100
readonly KEY_NAME="${AWS_KEY_NAME:-}"  # Set your key name or leave empty
readonly TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"  # Tailscale reusable auth key

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

# Build launch specification using jq for proper JSON
log_info "Launching Spot instance ($INSTANCE_TYPE)..."

LAUNCH_SPEC=$(jq -n \
  --arg ami "$AMI_ID" \
  --arg instance_type "$INSTANCE_TYPE" \
  --arg sg_id "$SG_ID" \
  --argjson volume_size "$VOLUME_SIZE_GB" \
  '{
    ImageId: $ami,
    InstanceType: $instance_type,
    SecurityGroupIds: [$sg_id],
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

# Add user-data to launch spec
LAUNCH_SPEC=$(echo "$LAUNCH_SPEC" | jq --arg ud "$USER_DATA" '. + {UserData: $ud}')

INSTANCE_ID=$(aws ec2 run-instances \
  --cli-input-json "$LAUNCH_SPEC" \
  --instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"persistent","InstanceInterruptionBehavior":"stop"}}' \
  --region "$REGION" \
  --query 'Instances[0].InstanceId' \
  --output text)

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
log_info "(this takes 2-3 minutes)"
echo ""

TAILSCALE_IP=""
MAX_ATTEMPTS=60  # 5 minutes max
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  ATTEMPT=$((ATTEMPT + 1))
  
  # Try to get Tailscale IP via SSH
  TAILSCALE_IP=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "ubuntu@$PUBLIC_IP" "tailscale ip -4 2>/dev/null" 2>/dev/null || echo "")
  
  if [ -n "$TAILSCALE_IP" ]; then
    break
  fi
  
  # Show progress every 10 seconds
  if [ $((ATTEMPT % 2)) -eq 0 ]; then
    echo -n "."
  fi
  
  sleep 5
done
echo ""

if [ -z "$TAILSCALE_IP" ]; then
  log_warn "Could not get Tailscale IP after 5 minutes."
  log_warn "Check cloud-init logs: ssh ubuntu@$PUBLIC_IP 'sudo cat /var/log/user-data.log'"
  TAILSCALE_IP="<run: ssh ubuntu@$PUBLIC_IP 'tailscale ip -4'>"
fi

log_info "Tailscale IP: $TAILSCALE_IP"
log_info ""

# Lock down security group
log_info "Locking down security group (removing public SSH)..."
aws ec2 revoke-security-group-ingress \
  --group-name "$SECURITY_GROUP_NAME" \
  --protocol tcp --port 22 --cidr 0.0.0.0/0 \
  --region "$REGION" 2>/dev/null || log_warn "SSH rule already removed or doesn't exist"
success "Public SSH access removed. Access now via Tailscale only."
log_info ""

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
echo "     │  Restrict to: flowslot"
echo "     └─────────────────────────────────────────────┘"
echo ""
echo "  4. Click 'Save'"
echo ""
echo "  5. Test DNS resolution:"
echo "     dig test.flowslot +short"
echo "     # Expected output: $TAILSCALE_IP"
echo ""
echo "  Without this, *.flowslot domains won't resolve!"
echo "============================================================"
echo ""
echo "Update your project's .slotconfig with:"
echo "  SLOT_REMOTE_HOST=\"ubuntu@$TAILSCALE_IP\""
echo "  SLOT_AWS_INSTANCE_ID=\"$INSTANCE_ID\""
echo ""
