# AIG Deployment — New VPC, Public Subnet

This template deploys the Netskope AI Gateway into a **brand-new VPC** with the gateway directly in a **public subnet** with an Elastic IP. This is the quickest path to a working gateway — the AIG is internet-accessible from day one.

Use this option when you want the fastest possible POV setup, or when clients need to reach the gateway over the internet. For production-like deployments without internet exposure, use [new-vpc-private](../new-vpc-private/README.md) instead.

---

## What this deploys

```
Internet
    │
    ▼
Internet Gateway
    │
    ▼
Public subnet (10.0.0.0/24)
  └── AI Gateway EC2 instance
         │  Elastic IP (public internet address)
         │  reads secret at boot
         ▼
     Secrets Manager (bootstrap secret)
```

**AWS resources created:**
- VPC with DNS support enabled
- Public subnet + Internet Gateway + route table
- Elastic IP (static public IP assigned to the gateway)
- Security group (inbound: TCP 443 from allowed CIDRs; outbound: all)
- IAM role + instance profile (least-privilege access to the bootstrap secret)
- Secrets Manager secret (enrollment token)
- EC2 instance (AIG appliance)

**Netskope resources created:**
- AIG appliance registration (host set to the Elastic IP allocated before EC2 launch)
- 24-hour enrollment token

---

## Prerequisites

- [ ] **Terraform ≥ 1.5** — [download here](https://developer.hashicorp.com/terraform/install)
- [ ] **AWS CLI profile** configured — see [Environment variables](#environment-variables) below
- [ ] **Netskope REST API v2 token** — Netskope tenant → Settings → Tools → REST API v2
- [ ] **Deployment IAM role** created — see [Step 0 in the main README](../README.md)

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

All variables have working defaults for us-west-1 — no required fields to fill in for a basic deployment.

```bash
cp terraform.tfvars.example terraform.tfvars
# Optionally edit terraform.tfvars to change the region or restrict allowed_cidr_blocks

terraform init
terraform apply
```

---

## Variables reference

### Required

This template has no required fields — all variables have working defaults for us-west-1.

### Network (optional)

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `"us-west-1"` | AWS region to deploy into |
| `availability_zone` | `"us-west-1b"` | Availability zone for the subnet — must be within `aws_region` |
| `vpc_cidr` | `"10.0.0.0/16"` | IP address range for the new VPC |
| `public_subnet_cidr` | `"10.0.0.0/24"` | CIDR for the public subnet — must be within `vpc_cidr` |
| `allowed_cidr_blocks` | `["0.0.0.0/0"]` | CIDRs allowed to reach the gateway on TCP 443. The default allows access from anywhere — restrict to your corporate network or client IP ranges for security. |

### EC2 (optional)

| Variable | Default | Description |
|----------|---------|-------------|
| `aig_ami_id` | _(auto from region map)_ | AMI ID for the AIG appliance. Auto-selected for: us-east-2, us-west-1, us-west-2, eu-central-1, ap-southeast-1. Set explicitly for any other region. |
| `instance_type` | `"c6a.4xlarge"` | EC2 instance size. `c6a.4xlarge` is the recommended minimum — the AIG requires at least 16 vCPU and 32 GB RAM. |
| `key_name` | _(none)_ | EC2 key pair name for SSH access. Optional — if provided, you can SSH directly to the instance's public Elastic IP. |

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
terraform plan   # review — should show ~11 resources being created
terraform apply
```

When complete, Terraform prints the outputs:

| Output | What it means |
|--------|---------------|
| `appliance_id` | The AIG appliance UUID in your Netskope tenant |
| `public_ip` | Elastic IP of the gateway — this is the address clients use to reach it |
| `instance_id` | EC2 instance ID |
| `bootstrap_secret_arn` | ARN of the Secrets Manager secret |
| `vpc_id` | VPC ID |

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
4. Configure clients to send traffic to `https://<public_ip>` on port 443

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

All AWS and Netskope resources created by this template are removed.

---

## Help

- [Troubleshooting guide](../docs/troubleshooting.md)
- [State management guide](../docs/state-management.md)
- [Main deployment README](../README.md)
