# AIG Deployment — Existing VPC

This template deploys the Netskope AI Gateway into a **VPC and subnet that already exist** in your AWS account. It creates only the gateway resources — IAM role, Secrets Manager secret, security group, and EC2 instance. Your existing networking is left untouched.

Use this option when your AWS environment is already set up and you want to place the gateway inside it.

## What gets deployed

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

## Before you start

You need:

- [ ] **Terraform ≥ 1.5** installed — [download here](https://developer.hashicorp.com/terraform/install)
- [ ] **AWS credentials** configured (`aws configure` or environment variables)
- [ ] **Netskope REST API v2 token** — Netskope tenant → Settings → Tools → REST API v2
- [ ] **AIG AMI ID** for your target AWS region — subscribe to the Netskope AI Gateway on AWS Marketplace and accept the terms; the AMI ID is shown after subscription
- [ ] **VPC ID** — from the AWS console or `aws ec2 describe-vpcs`
- [ ] **Subnet ID** — the subnet where the gateway will be placed; must have outbound internet access (via NAT gateway or Internet Gateway)
- [ ] **The IP or hostname the gateway will be reachable at** — usually its private IP in the subnet
- [ ] **Deployment IAM role** created — see [Step 0 in the main README](../README.md)

### Subnet requirements

The subnet must have a route to the internet (outbound only is sufficient) so the gateway can:
- Reach the Netskope cloud to enroll and process traffic
- Reach AWS Secrets Manager to read its bootstrap secret at boot

If your subnet is private, it needs a NAT gateway route. If it is public, the instance gets a public IP automatically (you may need `map_public_ip_on_launch = true` on the subnet, or associate an Elastic IP manually after deployment).

---

## Setup

### Step 1 — Find your VPC and subnet IDs

```bash
# List VPCs
aws ec2 describe-vpcs --region YOUR_REGION \
  --query 'Vpcs[*].{ID:VpcId,CIDR:CidrBlock,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table

# List subnets in a VPC
aws ec2 describe-subnets --region YOUR_REGION \
  --filters "Name=vpc-id,Values=vpc-YOUR_VPC_ID" \
  --query 'Subnets[*].{ID:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table
```

### Step 2 — Set Netskope credentials

Set these in your terminal session. Do not put them in any file.

```bash
export NETSKOPE_SERVER_URL="https://mycompany.goskope.com/api/v2"
export NETSKOPE_API_KEY="your-v2-api-token"
```

### Step 3 — Copy the configuration file

```bash
cd aig/existing-vpc
cp terraform.tfvars.example terraform.tfvars
```

### Step 4 — Edit `terraform.tfvars`

Open `terraform.tfvars` in a text editor and fill in your values. The table below documents every field.

#### Required fields

| Variable | Description | Example |
|----------|-------------|---------|
| `vpc_id` | ID of the existing VPC to deploy the gateway into | `"vpc-0123456789abcdef0"` |
| `subnet_id` | ID of the existing subnet for the gateway EC2 instance | `"subnet-0123456789abcdef0"` |
| `allowed_cidr_blocks` | List of CIDRs allowed to reach the gateway on TCP port 443 | `["10.0.0.0/8"]` |
| `aig_ami_id` | AMI ID for the AIG appliance in your target region. Subscribe to the Netskope AI Gateway on AWS Marketplace and accept the terms — the AMI ID is shown after subscription. | `"ami-0a66805d7fb085df4"` |
| `appliance_host` | The IP address or hostname the gateway will be reachable at. This is registered in the Netskope tenant for display purposes. Set it to the private IP you expect the instance to receive in the subnet, or a DNS name if you have one. It does not affect the enrollment handshake. | `"10.1.2.10"` |

#### AWS fields (optional)

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `"us-west-1"` | AWS region where your VPC lives. Must match the region of `vpc_id` and `subnet_id`. |

#### EC2 fields (optional)

| Variable | Default | Description |
|----------|---------|-------------|
| `instance_type` | `"c6a.4xlarge"` | EC2 instance size. `c6a.4xlarge` is the recommended minimum. Do not use a smaller instance type — the AIG requires at least 16 vCPU and 32 GB RAM. |
| `key_name` | _(none)_ | EC2 key pair name for SSH access. Optional. |

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

Read through the plan. It should show approximately 7 resources being created. No changes are made at this stage.

### Apply

```bash
terraform apply
```

Type `yes` when prompted. The deployment takes approximately 2 minutes.

When complete, Terraform prints the outputs:

```
appliance_id         = "01ab23cd-..."
aig_private_ip       = "10.x.x.x"
bootstrap_secret_arn = "arn:aws:secretsmanager:..."
instance_id          = "i-0abc123..."
```

| Output | What it means |
|--------|---------------|
| `appliance_id` | The AIG appliance UUID in your Netskope tenant |
| `aig_private_ip` | Private IP assigned to the gateway instance by AWS |
| `instance_id` | EC2 instance ID |
| `bootstrap_secret_arn` | ARN of the Secrets Manager secret |

> **Note:** If `aig_private_ip` differs from the `appliance_host` you set, update `appliance_host` in `terraform.tfvars` and run `terraform apply` again to keep the Netskope registration accurate.

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
4. Configure clients to send traffic to `https://AIG_PRIVATE_IP` (the value of `aig_private_ip` output)

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

Type `yes` when prompted. Only the resources created by this template are removed — your VPC, subnets, and other existing networking are not touched.

---

## Help

- [Troubleshooting guide](../docs/troubleshooting.md)
- [State management guide](../docs/state-management.md)
- [Main deployment README](../README.md)
