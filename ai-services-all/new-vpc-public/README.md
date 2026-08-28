# AI Services — New VPC (AIG + Guardrails + DLPoD)

Deploys a complete Netskope AI Services stack in a new AWS VPC with a single `terraform apply`. All three appliances are zero-touch provisioned — no manual registration steps.

## What gets deployed

```
Internet
    │ port 443
    ▼
┌─────────────────────────────────────────────────────────────┐
│  VPC (10.0.0.0/16)                                          │
│                                                              │
│  Public Subnet (10.0.1.0/24)                                │
│  ┌────────────────────┐   ┌──────────────┐                  │
│  │  AI Gateway (AIG)  │   │  NAT Gateway │                  │
│  │  EIP · port 443    │   │  EIP         │                  │
│  └────────┬───────────┘   └──────┬───────┘                  │
│           │                      │                           │
│  Private Subnet (10.0.2.0/24)   │                           │
│  ┌────────────────┐  ┌──────────┴───────┐                   │
│  │  Guardrails    │  │  DLPoD           │                   │
│  │  GPU · .10     │  │  m5.2xl · .20    │                   │
│  │  port 8080     │  │  port 443 (TLS)  │                   │
│  └────────────────┘  └──────────────────┘                   │
└─────────────────────────────────────────────────────────────┘
```

| Component | Subnet | Purpose |
|-----------|--------|---------|
| AI Gateway | Public | SSL termination, policy enforcement, routes AI traffic to Guardrails and DLP traffic to DLPoD |
| AI Guardrails | Private | GPU-backed LLM inference — scans AI content against Netskope policies |
| DLP On-Demand | Private | AI-aware DLP inspection — content scanning at AI query/response time |
| Bastion | Public | Troubleshooting access — **delete `bastion.tf` post-POV** |

## Terraform files

| File | Contents |
|------|----------|
| `main.tf` | Terraform config, providers, data sources, shared locals |
| `vpc.tf` | VPC, subnets, IGW, NAT gateway, route tables, VPC endpoints, Route 53 |
| `aig.tf` | Netskope appliance registration, Secrets Manager bootstrap, AIG IAM/SG/EC2 |
| `guardrails.tf` | Guardrails IAM, security group, CloudWatch, EC2, readiness gate |
| `dlpod.tf` | DLPoD TLS certificates, bootstrap config, IAM, security group, EC2, readiness gate |
| `bastion.tf` | Troubleshooting bastion (temporary — delete post-POV) |
| `variables.tf` | All input variable definitions |
| `outputs.tf` | Terraform outputs |

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — required: aig_ami_id, availability_zone, image_s3_bucket, dlpod_licensekey

export NETSKOPE_SERVER_URL="https://mycompany.goskope.com/api/v2"
export NETSKOPE_API_KEY="your-v2-token"

terraform init
terraform apply
```

Full deployment takes **30–50 minutes** (Guardrails two-phase setup: 15–30 min, DLPoD bootstrap: 5–10 min).

## Documentation

| Doc | Audience |
|-----|----------|
| [docs/deployment.md](docs/deployment.md) | Step-by-step deployment, prerequisites, variables reference, teardown |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Diagnostic commands, common failure modes, rebuild procedures |
| [docs/devops.md](docs/devops.md) | AWS services and why, bootstrap internals, AIG→DLPoD TLS validation, CI/CD integration |

## Key outputs

| Output | Description |
|--------|-------------|
| `aig_public_ip` | Elastic IP — configure AI clients to proxy through this on port 443 |
| `guardrails_ssm_connect_command` | SSM Session Manager connect command for the Guardrails instance |
| `dlp_host` | DLP host URL configured in the AIG bootstrap (`https://dlp.aigw.internal`) |
| `nat_gateway_ip` | Outbound IP for private subnet — add to firewall allowlists if needed |

## Rebuild reference

```bash
# AIG only (new token + new instance)
terraform taint netskope_aig_appliance_enrollment_token.this
terraform taint aws_secretsmanager_secret_version.aig_bootstrap
terraform taint aws_instance.aig && terraform apply

# Full AIG re-registration
terraform taint netskope_aig_appliance.this
terraform taint netskope_aig_appliance_enrollment_token.this
terraform taint aws_secretsmanager_secret_version.aig_bootstrap
terraform taint aws_instance.aig && terraform apply
```

See [docs/troubleshooting.md](docs/troubleshooting.md) for DLPoD and Guardrails rebuild procedures.
