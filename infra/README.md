# Flowslot Infrastructure Setup

One-time setup to create and configure the EC2 instance for flowslot.

## Prerequisites

- AWS CLI installed and configured
- AWS SSO access (or IAM credentials)
- SSH key pair configured in AWS (or use default)
- Tailscale account (free tier works)

## Step 1: Authenticate

```bash
aws sso login
aws sts get-caller-identity  # Verify
```

## Step 2: Create EC2 Instance

```bash
cd infra
./create-instance.sh
```

This will:
- Create security group `flowslot-dev` (SSH open initially)
- Launch t4g.2xlarge ARM Spot instance (100GB gp3 disk)
- Output instance ID and public IP

**Note:** The script uses Ubuntu 22.04 ARM64 AMI for eu-central-1. For other regions, update `AMI_ID` in `create-instance.sh`:
```bash
aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text \
  --region YOUR_REGION
```

## Step 3: Setup Remote Instance

```bash
./setup-remote.sh <public-ip>
```

This will:
- Install Docker
- Install Tailscale
- Deploy idle-check script
- Configure cron (auto-stop after 2 hours idle)

**After the script completes**, you need to authenticate Tailscale manually:
```bash
ssh ubuntu@<public-ip> "sudo tailscale up"
```
Follow the URL to authenticate. Once connected, run `setup-remote.sh` again to automatically lock down the security group.

## Step 4: Verify Security

After running `setup-remote.sh` with Tailscale connected, the script will:
- Automatically revoke public SSH access (port 22 from 0.0.0.0/0)
- Verify SSH works via Tailscale IP

If you need to manually lock down:
```bash
aws ec2 revoke-security-group-ingress \
  --group-name flowslot-dev \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0 \
  --region eu-central-1
```

Now SSH only works via Tailscale IP.

## Step 5: Configure Project

Use the instance ID and Tailscale IP when running `slot init`:

```bash
cd ~/development/your-project
slot init
# Enter:
#   AWS Instance ID: i-0abc123...
#   Remote host: ubuntu@100.x.y.z  # Tailscale IP
```

## Cost Optimization

- **Spot Instances:** ~70-80% cheaper than On-Demand
- **ARM (t4g):** ~20% cheaper than x86 (t3)
- **Auto-stop:** Idle instances stop after 2 hours (configurable via cron)
- **Manual control:** `slot server start/stop` for on-demand usage

Estimated cost: ~$0.08/hour when running (t4g.2xlarge Spot in eu-central-1)

## Idle Detection

The remote server monitors activity and shuts down after 2 hours of inactivity:

**Activity signals:**
- File changes (Mutagen sync)
- Active SSH sessions
- Docker containers using CPU (>0.5%)

**To disable:**
```bash
ssh ubuntu@<tailscale-ip> "crontab -l | grep -v flowslot-idle-check | crontab -"
```

**To change timeout** (e.g., 3 hours = 10800 seconds):
```bash
ssh ubuntu@<tailscale-ip> "sudo sed -i 's/IDLE_LIMIT=7200/IDLE_LIMIT=10800/' /usr/local/bin/flowslot-idle-check"
```
