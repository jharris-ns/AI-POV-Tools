# AIG Deployment — Existing VPC

This template deploys the Netskope AI Gateway into a **VPC and subnet that already exist** in your AWS account. It creates only the gateway resources — IAM role, Secrets Manager secret, security group, and EC2 instance. Your existing networking is left untouched.

Use this option when your AWS environment is already set up and you want to place the gateway inside it.

---

## What this deploys

```
Your existing VPC
  └── Your existing subnet
        └── AI Gateway EC2 instance
               │  reads secret at boot
               ▼
           Secrets Manager (bootstrap secret)
```

**AWS resources created:**
- Security group in your existing VPC (inbound: TCP 443; outbound: all)
- IAM role + instance profile (least-privilege access to the bootstrap secret)
- Secrets Manager secret (enrollment token)
- EC2 instance (AIG appliance) placed in your existing subnet

**Netskope resources created:**
- AIG appliance registration
- 24-hour enrollment token

**Nothing created or modified:**
- Your VPC, subnets, route tables, and internet/NAT gateways are not touched

---

## Prerequisites

- [ ] **Terraform ≥ 1.5** — [download here](https://developer.hashicorp.com/terraform/install)
- [ ] **AWS CLI profile** configured — see [Environment variables](#environment-variables) below
- [ ] **Netskope REST API v2 token** — Netskope tenant → Settings → Tools → REST API v2
- [ ] **VPC ID** — from the AWS console or `aws ec2 describe-vpcs`
- [ ] **Subnet ID** — the subnet where the gateway will be placed; must have outbound internet access (via NAT gateway or Internet Gateway)
- [ ] **The IP or hostname the gateway will be reachable at** — usually its private IP in the subnet
- [ ] **Deployment IAM role** created — see [Step 0 in the main README](../README.md)

### Subnet requirements

The subnet must have a route to the internet (outbound only is sufficient) so the gateway can reach the Netskope cloud to enroll and reach AWS Secrets Manager to read its bootstrap secret at boot.

---

## Environment variables

Set these in your terminal before running any Terraform command. Do not put them in `terraform.tfvars`.

```bash
export NETSKOPE_SERVER_URL="https://mycompany.goskope.com/api/v2"
export NETSKOPE_API_KEY="your-v2-api-token"
```

**AWS credentials:** A configured AWS CLI profile is required. If you haven't set one up, follow the [AWS CLI configuration guide](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html). Terraform picks up your default profile automatically — to use a named profile, run `export AWS_PROFILE=your-profile-name` before applying.

---

## Quick start

```bash
# Find your VPC and subnet IDs:
aws ec2 describe-vpcs --region YOUR_REGION --output table
aws ec2 describe-subnets --region YOUR_REGION \
  --filters "Name=vpc-id,Values=YOUR_VPC_ID" --output table

cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — fill in: vpc_id, subnet_id, allowed_cidr_blocks, appliance_host

terraform init
terraform apply
```

---

## Variables reference

### Required

| Variable | Description | Example |
|----------|-------------|---------|
| `vpc_id` | ID of the existing VPC to deploy the gateway into | `"vpc-0123456789abcdef0"` |
| `subnet_id` | ID of the existing subnet for the gateway EC2 instance | `"subnet-0123456789abcdef0"` |
| `allowed_cidr_blocks` | List of CIDRs allowed to reach the gateway on TCP 443 | `["10.0.0.0/8"]` |
| `appliance_host` | IP address or hostname the gateway will be reachable at. Registered in the Netskope tenant for display — does not affect the enrollment handshake. | `"10.1.2.10"` |

### AWS (optional)

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `"us-west-1"` | AWS region where your VPC lives. Must match the region of `vpc_id` and `subnet_id`. |

### EC2 (optional)

| Variable | Default | Description |
|----------|---------|-------------|
| `aig_ami_id` | _(auto from region map)_ | AMI ID for the AIG appliance. Auto-selected for: us-east-2, us-west-1, us-west-2, eu-central-1, ap-southeast-1. Set explicitly for any other region. |
| `instance_type` | `"c6a.4xlarge"` | EC2 instance size. `c6a.4xlarge` is the recommended minimum — the AIG requires at least 16 vCPU and 32 GB RAM. |
| `key_name` | _(none)_ | EC2 key pair name for SSH access. Optional. |

### Netskope and naming (optional)

| Variable | Default | Description |
|----------|---------|-------------|
| `appliance_name` | `"aig-pov"` | Display name in the Netskope tenant and prefix for all AWS resource Name tags. Must be 1–15 characters and start with `aig-` to match the deployment IAM policy. |
| `secret_name` | `"aig/prod/bootstrap"` | Secrets Manager secret name. Must start with `aig/` to match the deployment IAM policy. |

> `NETSKOPE_SERVER_URL` and `NETSKOPE_API_KEY` are read from environment variables. You can set them in `terraform.tfvars` as `netskope_server_url` and `netskope_api_key` instead, but environment variables are safer — the tfvars file is not encrypted.

---

## Remote state (optional but recommended)

By default Terraform stores state locally in `terraform.tfstate`. For team use or to protect against data loss, store state in S3.

```bash
cp backend.hcl.example backend.hcl
# Edit backend.hcl — fill in your S3 bucket name and region
terraform init -backend-config=backend.hcl
```

See [docs/state-management.md](../docs/state-management.md) for instructions on creating the S3 bucket and DynamoDB lock table.

---

## Deploy

```bash
terraform init
terraform plan   # review — should show ~7 resources being created
terraform apply
```

When complete, Terraform prints the outputs:

| Output | What it means |
|--------|---------------|
| `appliance_id` | The AIG appliance UUID in your Netskope tenant |
| `aig_private_ip` | Private IP assigned to the gateway instance by AWS |
| `instance_id` | EC2 instance ID |
| `bootstrap_secret_arn` | ARN of the Secrets Manager secret |

> If `aig_private_ip` differs from the `appliance_host` you set, update `appliance_host` in `terraform.tfvars` and run `terraform apply` again to keep the Netskope registration accurate.

---

## Verify enrollment

Allow up to **15 minutes** after `terraform apply` completes for the gateway to boot and enroll.

```bash
curl -s -H "Netskope-Api-Token: $NETSKOPE_API_KEY" \
  "$NETSKOPE_SERVER_URL/aig/appliances" \
  | jq '.elements[] | {name, status}'
```

A `"status": "connected"` response confirms successful enrollment. You can also check via **Settings → Security Cloud Platform → VM Onboarding** in the Netskope UI.

---

## Configure AI providers

Once enrolled:

1. Go to **Settings → Security Cloud Platform → AI Gateways**
2. Select your appliance
3. Add AI providers (OpenAI, Anthropic, etc.)
4. Configure clients to send traffic to `https://<aig_private_ip>` on port 443

---

## Re-enrollment

The enrollment token is valid for **24 hours**. If the gateway has not enrolled within that window:

```bash
terraform apply
```

Terraform replaces the token resource, updates the secret, and the gateway picks up the new token on next boot.

---

## Tear down

```bash
terraform destroy
```

Only the resources created by this template are removed — your VPC, subnets, and other existing networking are not touched.

---

## Help

- [Troubleshooting guide](../docs/troubleshooting.md)
- [State management guide](../docs/state-management.md)
- [Main deployment README](../README.md)
