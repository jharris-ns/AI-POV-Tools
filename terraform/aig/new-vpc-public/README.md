# AIG Deployment — New VPC, Public Subnet

This template deploys the Netskope AI Gateway into a **brand-new VPC** with the gateway directly in a **public subnet** with an Elastic IP. This is the quickest path to a working gateway — the AIG is internet-accessible from day one.

Use this option when you want the fastest possible POV setup, or when clients need to reach the gateway over the internet. For production-like deployments without internet exposure, use [new-vpc-private](../new-vpc-private/README.md) instead.

## What gets deployed

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
cd terraform/aig/new-vpc-public
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
| `availability_zone` | `"us-west-1b"` | Availability zone for the subnet. Must be within `aws_region`. |
| `vpc_cidr` | `"10.0.0.0/16"` | IP address range for the new VPC. Change if this overlaps with existing networks you need to connect to. |
| `public_subnet_cidr` | `"10.0.0.0/24"` | CIDR for the public subnet. Must be within `vpc_cidr`. |
| `allowed_cidr_blocks` | `["0.0.0.0/0"]` | List of CIDRs allowed to reach the gateway on TCP port 443. The default allows access from anywhere — restrict this to your corporate network or client IP ranges for security. |

#### EC2 fields (optional)

| Variable | Default | Description |
|----------|---------|-------------|
| `instance_type` | `"c6a.4xlarge"` | EC2 instance size. `c6a.4xlarge` is the recommended minimum. Do not use a smaller instance type — the AIG requires at least 16 vCPU and 32 GB RAM. |
| `key_name` | _(none)_ | EC2 key pair name for SSH access. Optional — if you need to access the instance, you can SSH directly to its public IP if a key pair is provided. |

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

Read through the plan. It should show approximately 11 resources being created. No changes are made at this stage.

### Apply

```bash
terraform apply
```

Type `yes` when prompted. The deployment takes approximately 2–3 minutes.

When complete, Terraform prints the outputs:

```
appliance_id         = "01ab23cd-..."
bootstrap_secret_arn = "arn:aws:secretsmanager:..."
instance_id          = "i-0abc123..."
public_ip            = "52.x.x.x"
vpc_id               = "vpc-0abc123..."
```

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
4. Configure clients to send traffic to `https://PUBLIC_IP` where `PUBLIC_IP` is the value of the `public_ip` output

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

Type `yes` when prompted. All AWS and Netskope resources created by this template are removed.

---

## Help

- [Troubleshooting guide](../docs/troubleshooting.md)
- [State management guide](../docs/state-management.md)
- [Main deployment README](../README.md)
