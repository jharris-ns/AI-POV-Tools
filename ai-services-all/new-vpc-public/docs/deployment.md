# Deployment Guide

## Overview

This Terraform deployment provisions a complete Netskope AI Services stack in a new AWS VPC:

- **AI Gateway (AIG)** — public subnet, internet-facing on port 443
- **AI Guardrails** — private subnet, GPU-backed LLM inference service
- **DLP On-Demand (DLPoD)** — private subnet, AI-aware DLP inspection service
- **Bastion** — public subnet, SSM + SSH access for troubleshooting (delete post-POV)

All three appliances are zero-touch provisioned: Terraform generates credentials, writes bootstrap config, and gates each stage on the previous one being ready before proceeding.

---

## Prerequisites

### AWS
- AWS CLI configured with credentials that have sufficient IAM permissions
- An S3 bucket in the target region containing `aisecurity-llm.tgz` (Guardrails Docker image)
- The Netskope AIG AMI subscribed on AWS Marketplace for your target region
- The Netskope DLPoD AMI (default `ami-0b3a14615c7e7944e` is for us-west-1 — update for other regions)
- EC2 key pairs (optional — SSM Session Manager is available without them)

### Netskope
- Netskope tenant with AI Gateway entitlement
- REST API v2 token with permissions to create AIG appliances

### Terraform
- Terraform >= 1.5
- Network access to the Netskope tenant API during `terraform apply`

---

## Credentials

Set these as environment variables — do not put them in `terraform.tfvars`:

```bash
export NETSKOPE_SERVER_URL="https://mycompany.goskope.com/api/v2"
export NETSKOPE_API_KEY="your-rest-api-v2-token"
```

AWS credentials via standard methods (`aws configure`, `AWS_PROFILE`, instance role, etc.).

---

## Quick Start

```bash
# 1. Copy and edit the vars file
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — at minimum set: aig_ami_id, dlpod_ami_id, image_s3_bucket, dlpod_licensekey

# 2. Upload the Guardrails image to S3
aws s3 cp aisecurity-llm.tgz s3://my-guardrails-bucket/aisecurity-llm.tgz

# 3. Set credentials
export NETSKOPE_SERVER_URL="https://mycompany.goskope.com/api/v2"
export NETSKOPE_API_KEY="your-token"

# 4. Deploy
terraform init
terraform apply
```

`terraform apply` will take **30-50 minutes** end-to-end due to the readiness gates:
- Guardrails two-phase setup: 15-30 min (NVIDIA drivers + Docker + image load)
- DLPoD bootstrap: 5-10 min (cert install + service start)
- AIG instance creation: 2-3 min

---

## Key Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `aig_ami_id` | Yes | — | AIG AMI ID for your region (from AWS Marketplace) |
| `dlpod_ami_id` | No* | `ami-0b3a14615c7e7944e` | DLPoD AMI ID — default is us-west-1; **update for other regions** |
| `image_s3_bucket` | Yes | — | S3 bucket containing `aisecurity-llm.tgz` |
| `dlpod_licensekey` | Yes | — | Netskope license key for DLPoD |
| `aws_region` | No | `us-east-1` | AWS region |
| `availability_zone` | Yes | — | AZ within `aws_region` |
| `appliance_name` | No | `aig-pov` | AIG display name in Netskope tenant (1-15 chars) |
| `aig_instance_type` | No | `c6a.4xlarge` | AIG instance type |
| `guardrails_instance_type` | No | `g4dn.xlarge` | GPU instance type for Guardrails |
| `guardrails_private_ip` | No | `10.0.2.10` | Fixed private IP — do not change after apply |
| `dlpod_private_ip` | No | `10.0.2.20` | Fixed private IP — do not change after apply |
| `dlpod_hostname` | No | `dlp.aigw.internal` | TLS CN / DNS SAN for DLPoD cert |
| `allowed_cidr_blocks` | No | `["0.0.0.0/0"]` | CIDRs permitted to reach AIG on port 443 |

> **\* `dlpod_ami_id`** has a default but it is region-specific. The default (`ami-0b3a14615c7e7944e`) is only valid in us-west-1 — set it explicitly for any other region.
>
> **Note:** `guardrails_private_ip` and `dlpod_private_ip` are embedded in the AIG bootstrap secret at plan time. Changing them after `terraform apply` requires tainting the secret and AIG instance.

---

## Outputs

After a successful apply:

| Output | Description |
|--------|-------------|
| `aig_public_ip` | Elastic IP of the AIG — configure clients to proxy through this |
| `aig_instance_id` | EC2 instance ID of the AIG |
| `appliance_id` | Netskope appliance UUID |
| `guardrails_ssm_connect_command` | SSM Session Manager connect command for Guardrails |
| `dlp_host` | DLP host URL in the bootstrap secret (`https://dlp.aigw.internal`) |

---

## Remote State (Recommended)

Terraform state contains TLS private keys. Use S3 remote state with SSE-KMS:

```hcl
# backend.hcl
bucket         = "my-tfstate-bucket"
key            = "ai-services/new-vpc-public/terraform.tfstate"
region         = "us-west-1"
encrypt        = true
kms_key_id     = "arn:aws:kms:us-west-1:123456789:key/..."
dynamodb_table = "terraform-state-lock"
```

```bash
terraform init -backend-config=backend.hcl
```

---

## Teardown

```bash
terraform plan -destroy   # review what will be destroyed
terraform destroy
```

All resources are destroyed including the Netskope appliance registration, EIPs, VPC, and Secrets Manager secret (with `recovery_window_in_days = 0` — immediate deletion).
