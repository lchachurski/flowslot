# Flowslot Infrastructure Setup

One-time setup to create and configure the EC2 instance for flowslot.

## Prerequisites

- AWS CLI installed and configured
- AWS SSO access (or IAM credentials)
- SSH key pair configured in AWS (or use default)

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
- Create security group `flowslot-dev`
- Launch t3.2xlarge Spot instance (100GB gp3 disk)
- Output instance ID and public IP

**Note:** Update `AMI_ID` in `create-instance.sh` for your region. Find Ubuntu 22.04 AMI:
```bash
aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
  --output text \
  --region eu-central-1
```

## Step 3: Setup Remote Instance

```bash
./setup-remote.sh <public-ip>
```

This will:
- Install Docker
- Install Tailscale (you'll need to authenticate)
- Deploy idle-check script
- Configure cron (auto-stop after 1 hour idle)

**Tailscale Authentication:**
When prompted, run `sudo tailscale up` on the remote server. This will give you a URL to authenticate.

## Step 4: Lock Down Security Group

After Tailscale is working, remove public SSH access:

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

- **Spot Instances:** ~70% cheaper than On-Demand
- **Auto-stop:** Idle instances stop after 1 hour (via cron)
- **Manual control:** `slot server start/stop` for on-demand usage

Estimated cost: ~$0.10/hour when running (t3.2xlarge Spot in eu-central-1)

