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

show_help() {
  cat << 'EOF'
Usage: ./create-instance.sh

Creates an AWS EC2 Spot instance for flowslot development.

Prerequisites:
  - AWS CLI configured
  - Run 'aws sso login' first

Environment variables:
  AWS_REGION     Region to create instance in (default: eu-central-1)
  AWS_KEY_NAME   SSH key pair name (optional)

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

log_info "Creating EC2 Spot instance in $REGION..."

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
log_info "Next steps:"
log_info "  1. Run: ./setup-remote.sh $PUBLIC_IP"
log_info "  2. After Tailscale is configured, lock down security group:"
log_info "     aws ec2 revoke-security-group-ingress \\"
log_info "       --group-name $SECURITY_GROUP_NAME \\"
log_info "       --protocol tcp --port 22 --cidr 0.0.0.0/0 \\"
log_info "       --region $REGION"
