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

# Substitute TAILSCALE_AUTH_KEY in user-data and base64 encode
if [ -n "$TAILSCALE_AUTH_KEY" ]; then
  USER_DATA=$(sed "s/\${TAILSCALE_AUTH_KEY}/$TAILSCALE_AUTH_KEY/g" "$USER_DATA_FILE" | base64 -w0)
else
  # Still pass user-data but without auth key substitution
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
log_info "User-data script is running on the instance (cloud-init)."
log_info "This will install Docker, Tailscale, dnsmasq, and idle-check automatically."
log_info ""
if [ -n "$TAILSCALE_AUTH_KEY" ]; then
  log_info "Tailscale auth key provided - instance should auto-connect."
  log_info "Check Tailscale IP with: aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].Tags[?Key==\`TailscaleIP\`].Value' --output text"
else
  log_info "Tailscale auth key NOT provided - manual setup required:"
  log_info "  1. SSH: ssh ubuntu@$PUBLIC_IP"
  log_info "  2. Run: sudo tailscale up"
  log_info "  3. Follow the URL to authenticate"
fi
log_info ""
log_info "Next steps:"
log_info "  1. Wait 2-3 minutes for cloud-init to complete"
log_info "  2. Get Tailscale IP from instance or Tailscale admin console"
log_info "  3. Configure Tailscale Split DNS:"
log_info "     - Go to https://login.tailscale.com/admin/dns"
log_info "     - Add nameserver: <tailscale-ip>"
log_info "     - Restrict to domain: flowslot"
log_info "  4. Lock down security group (remove public SSH):"
log_info "     aws ec2 revoke-security-group-ingress \\"
log_info "       --group-name $SECURITY_GROUP_NAME \\"
log_info "       --protocol tcp --port 22 --cidr 0.0.0.0/0 \\"
log_info "       --region $REGION"
log_info ""
log_info "View cloud-init logs:"
log_info "  ssh ubuntu@$PUBLIC_IP 'sudo cat /var/log/user-data.log'"
