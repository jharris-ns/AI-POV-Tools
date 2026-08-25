# Netskope AI Gateway — Terraform Templates

Automated deployment of the Netskope AI Gateway (AIG) appliance on AWS using
the [Netskope Terraform provider](https://registry.terraform.io/providers/netskopeoss/netskope/latest)
and AWS Secrets Manager bootstrap. No SSH access or manual CLI steps required.

---

## Choose a deployment option

| Option | Directory | When to use |
|--------|-----------|-------------|
| Existing VPC | `existing-vpc/` | You have a VPC and subnet already. Bring your own networking. |
| New VPC — public subnet | `new-vpc-public/` | Quickest POV. AIG gets a public Elastic IP. Suitable when clients access the AIG directly over the internet or from a VPN terminating outside AWS. |
| New VPC — private subnet | `new-vpc-private/` | Recommended for production-like POVs. AIG sits behind a NAT Gateway — no inbound internet exposure. Clients access via VPC peering, VPN, or other instances in the same VPC. |

---

## Step 0: Create the deployment role (first time only)

Before running any deployment template, create the scoped IAM role that
Terraform will use. You only need to do this once per AWS account.

```bash
cd deployment-role
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — add your IAM user/role ARN to trusted_principal_arns
terraform init && terraform apply
```

This creates an IAM role (`aig-deployment-role`) and policy with the minimum
permissions required to deploy, update, and destroy AIG resources. Assume this
role before running any of the deployment templates below.

```bash
# Assume the deployment role (adjust profile/method to your AWS setup)
aws sts assume-role \
  --role-arn "$(terraform output -raw role_arn)" \
  --role-session-name aig-deploy
```

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| Terraform ≥ 1.5 | `brew install terraform` or [terraform.io](https://www.terraform.io/downloads) |
| AWS credentials | `aws configure` or environment variables (`AWS_ACCESS_KEY_ID`, etc.) |
| Netskope API credentials | REST API v2 token from your Netskope tenant (see below) |
| AIG AMI ID | Obtain from your Netskope account team |

### Netskope API token

1. Log in to your Netskope tenant
2. Go to **Settings → Tools → REST API v1 and REST API v2**
3. Generate a REST API **v2** token with at minimum the **AIG** scope
4. Export it as an environment variable — do not put it in your tfvars file:

```bash
export NETSKOPE_SERVER_URL="https://mycompany.goskope.com/api/v2"
export NETSKOPE_API_KEY="your-token-here"
```

---

## Quick start

### 1. Pick a directory and copy the example tfvars

```bash
# Choose one:
cd existing-vpc
cd new-vpc-public
cd new-vpc-private

cp terraform.tfvars.example terraform.tfvars
```

### 2. Edit `terraform.tfvars`

Open `terraform.tfvars` and fill in the required values. Each file has inline
comments explaining what each variable does. The minimum required values for
each option are:

**existing-vpc**
```hcl
vpc_id         = "vpc-..."
subnet_id      = "subnet-..."
appliance_host = "10.x.x.x"     # IP or hostname the AIG will be reachable at
aig_ami_id     = "ami-..."
allowed_cidr_blocks = ["10.x.x.x/x"]
```

**new-vpc-public**
```hcl
aig_ami_id = "ami-..."           # all other values have working defaults
```

**new-vpc-private**
```hcl
aig_ami_id     = "ami-..."
aig_private_ip = "10.0.1.10"    # must be within private_subnet_cidr
```

### 3. Set Netskope credentials

```bash
export NETSKOPE_SERVER_URL="https://mycompany.goskope.com/api/v2"
export NETSKOPE_API_KEY="your-token-here"
```

### 4. Deploy

```bash
terraform init
terraform apply
```

Terraform will:
1. Register the AIG appliance in your Netskope tenant
2. Generate a 24-hour enrollment token
3. Store the token in AWS Secrets Manager
4. Create the IAM role and instance profile
5. Launch the EC2 instance — it reads the secret at first boot and self-enrolls

---

## Verify enrollment

Allow up to 15 minutes after the instance launches for enrollment to complete.

**Option 1 — Netskope UI**

Go to **Settings → Security Cloud Platform → VM Onboarding** and look for a
green icon next to your appliance name.

**Option 2 — API**

```bash
curl -s -H "Netskope-Api-Token: $NETSKOPE_API_KEY" \
  "$NETSKOPE_SERVER_URL/aig/appliances" | jq '.elements[] | {name, status}'
```

A `status` of `connected` confirms successful enrollment.

---

## Enrollment token TTL

The enrollment token is valid for **24 hours** from `terraform apply`. If the
EC2 instance has not enrolled within that window, run `terraform apply` again —
the token resource is create-only and will generate a fresh token, which
automatically updates the Secrets Manager secret.

---

## Outputs

All three options expose these outputs after `terraform apply`:

| Output | Description |
|--------|-------------|
| `appliance_id` | Netskope AIG appliance UUID |
| `instance_id` | EC2 instance ID |
| `bootstrap_secret_arn` | Secrets Manager secret ARN |

Additional outputs vary by option (e.g. `public_ip` for `new-vpc-public`,
`nat_public_ip` + `aig_private_ip` for `new-vpc-private`).

---

## Tear down

```bash
terraform destroy
```

The Secrets Manager secret has `recovery_window_in_days = 0` so it is deleted
immediately, allowing the same secret name to be reused on re-deploy.
