# AIG Deployment — New VPC, Private Subnet

This template deploys the Netskope AI Gateway into a **brand-new VPC** with the gateway in a **private subnet**. Outbound internet access is provided by a NAT Gateway — the gateway has no inbound exposure from the internet.

This is the recommended option for production-like POVs. Clients (browsers, applications) reach the gateway from within the same VPC, via VPC peering, or via VPN.

## What gets deployed

```
Internet
    │
    ▼
Internet Gateway
    │
    ▼
Public subnet (10.0.0.0/24)
  └── NAT Gateway ──────────────────────► Netskope cloud
         │                                (enrollment + AI traffic)
         ▼
Private subnet (10.0.1.0/24)
  └── AI Gateway EC2 instance (10.0.1.10)
         │  reads secret at boot
         ▼
     Secrets Manager (bootstrap secret)
```

**AWS resources created:**
- VPC with DNS support enabled
- Public subnet + Internet Gateway + route table
- Private subnet + NAT Gateway + route table
- Elastic IP for the NAT Gateway
- Security group (inbound: TCP 443 from allowed CIDRs; outbound: all)
- IAM role + instance profile (least-privilege access to the bootstrap secret)
- Secrets Manager secret (enrollment token)
- EC2 instance (AIG appliance)

**Netskope resources created:**
- AIG appliance registration
- 24-hour enrollment token

---

## Before you start

You need:

- [ ] **Terraform ≥ 1.5** installed — [download here](https://developer.hashicorp.com/terraform/install)
- [ ] **AWS credentials** configured (`aws configure` or environment variables)
- [ ] **Netskope REST API v2 token** — Netskope tenant → Settings → Tools → REST API v2
- [ ] **AIG AMI ID** for your target AWS region — obtain from your Netskope account team
- [ ] **Deployment IAM role** created — see [Step 0 in the main README](../README.md)

---

## Setup

### Step 1 — Set Netskope credentials

Set these in your terminal session. Do not put them in any file.

```bash
export NETSKOPE_SERVER_URL="https://mycompany.goskope.com/api/v2"
export NETSKOPE_API_KEY="your-v2-api-token"
```

### Step 2 — Copy the configuration file

```bash
cd terraform/aig/new-vpc-private
cp terraform.tfvars.example terraform.tfvars
```

### Step 3 — Edit `terraform.tfvars`

Open `terraform.tfvars` in a text editor and fill in your values. The table below documents every field.

#### Required fields

| Variable | Description | Example |
|----------|-------------|---------|
| `aig_ami_id` | AMI ID for the AIG appliance in your target region. Obtain from Netskope. | `"ami-0a66805d7fb085df4"` |

#### Network fields (optional — defaults work for most POVs)

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `"us-west-1"` | AWS region to deploy into. Must match the region your AMI is available in. |
| `availability_zone` | `"us-west-1b"` | Availability zone for the subnets. Must be within `aws_region`. |
| `vpc_cidr` | `"10.0.0.0/16"` | IP address range for the new VPC. Change if this overlaps with existing networks you need to peer or connect to. |
| `public_subnet_cidr` | `"10.0.0.0/24"` | CIDR for the public subnet (NAT Gateway only — no AIG instances here). Must be within `vpc_cidr`. |
| `private_subnet_cidr` | `"10.0.1.0/24"` | CIDR for the private subnet (AIG instance). Must be within `vpc_cidr` and not overlap with `public_subnet_cidr`. |
| `aig_private_ip` | `"10.0.1.10"` | Fixed private IP for the AIG instance. Must be within `private_subnet_cidr`. This IP is registered in Netskope at plan time and pinned to the EC2 instance — they must match. |
| `allowed_cidr_blocks` | `["10.0.0.0/16"]` | List of CIDRs that are allowed to reach the gateway on TCP port 443. Typically your corporate network or VPC CIDR. |

#### EC2 fields (optional)

| Variable | Default | Description |
|----------|---------|-------------|
| `instance_type` | `"c6a.4xlarge"` | EC2 instance size. `c6a.4xlarge` is the recommended minimum. Do not use a smaller instance type — the AIG requires at least 16 vCPU and 32 GB RAM. |
| `key_name` | _(none)_ | EC2 key pair name for SSH access. Optional — if omitted you can still access the instance via AWS Systems Manager Session Manager. |

#### Netskope and naming fields (optional)

| Variable | Default | Description |
|----------|---------|-------------|
| `appliance_name` | `"aig-pov"` | Display name for the appliance in the Netskope tenant. Also used as the prefix for all AWS resource Name tags. Must be 1–15 characters (Netskope limit). Must start with `aig-` to match the deployment IAM policy. |
| `secret_name` | `"aig/prod/bootstrap"` | Secrets Manager secret name. Must start with `aig/` to match the deployment IAM policy. |

> **Note:** `NETSKOPE_SERVER_URL` and `NETSKOPE_API_KEY` are read from environment variables. You can set them in `terraform.tfvars` instead as `netskope_server_url` and `netskope_api_key`, but environment variables are safer — the tfvars file is not encrypted.

---

## Remote state (optional but recommended)

By default Terraform stores state locally in `terraform.tfstate`. For team use or to protect against data loss, store state in S3.

```bash
cp backend.hcl.example backend.hcl
# Edit backend.hcl — fill in your S3 bucket name and region
```

See [docs/state-management.md](../docs/state-management.md) for instructions on creating the S3 bucket and DynamoDB lock table before this step.

---

## Deploy

### Initialise Terraform

```bash
terraform init
```

If using remote state:
```bash
terraform init -backend-config=backend.hcl
```

### Preview the changes

```bash
terraform plan
```

Read through the plan. It should show approximately 14 resources being created. No changes are made at this stage.

### Apply

```bash
terraform apply
```

Type `yes` when prompted. The deployment takes approximately 3–5 minutes, most of which is the NAT Gateway provisioning.

When complete, Terraform prints the outputs:

```
appliance_id         = "01ab23cd-..."
aig_private_ip       = "10.0.1.10"
bootstrap_secret_arn = "arn:aws:secretsmanager:..."
instance_id          = "i-0abc123..."
nat_public_ip        = "52.x.x.x"
vpc_id               = "vpc-0abc123..."
```

| Output | What it means |
|--------|---------------|
| `appliance_id` | The AIG appliance UUID in your Netskope tenant |
| `aig_private_ip` | Private IP of the gateway instance |
| `nat_public_ip` | Public IP the gateway uses for outbound traffic (add this to any allow-lists) |
| `instance_id` | EC2 instance ID (for use with AWS console or SSM) |
| `bootstrap_secret_arn` | ARN of the Secrets Manager secret |
| `vpc_id` | VPC ID (needed if you configure VPC peering later) |

---

## Verify enrollment

Allow up to **15 minutes** after `terraform apply` completes for the gateway to boot and enroll.

**Check via API:**
```bash
curl -s -H "Netskope-Api-Token: $NETSKOPE_API_KEY" \
  "$NETSKOPE_SERVER_URL/aig/appliances" \
  | jq '.elements[] | {name, status}'
```

A `"status": "connected"` response confirms successful enrollment.

**Check via Netskope UI:**
Go to **Settings → Security Cloud Platform → VM Onboarding** and look for a green connected icon next to your appliance name.

---

## Configure AI providers

Once enrolled, assign AI providers to the gateway in the Netskope tenant:

1. Go to **Settings → Security Cloud Platform → AI Gateways**
2. Select your appliance
3. Add AI providers (OpenAI, Anthropic, etc.)
4. Configure clients to send traffic to `https://10.0.1.10` (or whichever `aig_private_ip` you set)

---

## Re-enrollment (if the token expires)

The enrollment token is valid for **24 hours**. If the gateway has not enrolled within that window, regenerate the token:

```bash
terraform apply
```

Terraform replaces the token resource, updates the secret, and the gateway will pick up the new token on next boot.

---

## Tear down

```bash
terraform destroy
```

Type `yes` when prompted. All AWS and Netskope resources created by this template are removed. The Secrets Manager secret is deleted immediately (no recovery window) so the same secret name can be reused immediately.

---

## Help

- [Troubleshooting guide](../docs/troubleshooting.md)
- [State management guide](../docs/state-management.md)
- [Main deployment README](../README.md)
