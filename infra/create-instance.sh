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
  log_error() { echo "[ERROR] $*" >&2; }
  die() { log_error "$*"; exit 1; }
  require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
fi

require_cmd aws
require_cmd jq

REGION="${AWS_REGION:-eu-central-1}"
INSTANCE_TYPE="t3.2xlarge"
AMI_ID="ami-0c7217cdde317cfec"  # Ubuntu 22.04 LTS (update for your region)
SECURITY_GROUP_NAME="flowslot-dev"
KEY_NAME="${AWS_KEY_NAME:-}"  # Set your key name or leave empty to use default

log_info "Creating EC2 Spot instance in $REGION..."
echo ""

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
  
  echo "  Created: $SG_ID"
else
  log_info "Security group exists: $SG_ID"
fi

# Launch Spot instance
echo ""
log_info "Launching Spot instance ($INSTANCE_TYPE)..."

LAUNCH_SPEC="{
  \"ImageId\": \"$AMI_ID\",
  \"InstanceType\": \"$INSTANCE_TYPE\",
  \"SecurityGroupIds\": [\"$SG_ID\"],
  \"BlockDeviceMappings\": [{
    \"DeviceName\": \"/dev/sda1\",
    \"Ebs\": {
      \"VolumeSize\": 100,
      \"VolumeType\": \"gp3\",
      \"DeleteOnTermination\": true
    }
  }],
  \"TagSpecifications\": [{
    \"ResourceType\": \"instance\",
    \"Tags\": [
      {\"Key\": \"Name\", \"Value\": \"flowslot-dev\"},
      {\"Key\": \"Project\", \"Value\": \"flowslot\"}
    ]
  }]
}"

if [ -n "$KEY_NAME" ]; then
  LAUNCH_SPEC=$(echo "$LAUNCH_SPEC" | jq ". + {\"KeyName\": \"$KEY_NAME\"}")
fi

INSTANCE_ID=$(aws ec2 run-instances \
  --cli-input-json "$LAUNCH_SPEC" \
  --instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time","InstanceInterruptionBehavior":"stop"}}' \
  --region "$REGION" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "  Instance ID: $INSTANCE_ID"
echo ""
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

echo ""
success "Instance created successfully!"
echo ""
echo "Instance ID: $INSTANCE_ID"
echo "Public IP: $PUBLIC_IP"
echo "Region: $REGION"
echo ""
echo "Next steps:"
echo "  1. Run: ./setup-remote.sh $PUBLIC_IP"
echo "  2. After Tailscale is configured, lock down security group:"
echo "     aws ec2 revoke-security-group-ingress \\"
echo "       --group-name $SECURITY_GROUP_NAME \\"
echo "       --protocol tcp --port 22 --cidr 0.0.0.0/0 \\"
echo "       --region $REGION"

