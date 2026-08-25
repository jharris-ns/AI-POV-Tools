# Netskope AI Gateway — Terraform Deployment

This repository provides three Terraform templates for deploying the Netskope AI Gateway (AIG) appliance on AWS. Each template uses automated Secrets Manager bootstrap — the gateway self-enrolls at first boot with no SSH or manual steps required.

---

## Which option should I use?

```
Do you have an existing VPC and subnet?
├── Yes → existing-vpc/      Deploys only the gateway into your network
└── No  → Does the gateway need to be reachable from outside AWS?
          ├── No  → new-vpc-private/   Recommended for production-like POVs
          └── Yes → new-vpc-public/    Quickest path for internet-accessible demos
```

| Option | Directory | What gets created | Best for |
|--------|-----------|------------------|---------|
| [Existing VPC](existing-vpc/README.md) | `existing-vpc/` | IAM role, Secrets Manager secret, security group, EC2 instance | You already have a VPC and subnet |
| [New VPC — public](new-vpc-public/README.md) | `new-vpc-public/` | VPC, public subnet, internet gateway, Elastic IP, IAM, Secrets Manager, EC2 | Quickest POV, internet-accessible gateway |
| [New VPC — private](new-vpc-private/README.md) | `new-vpc-private/` | VPC, public + private subnets, NAT gateway, IAM, Secrets Manager, EC2 | Production-like POV, no inbound internet exposure |

---

## Prerequisites

Before deploying any option you need:

| Requirement | How to get it |
|-------------|---------------|
| **Terraform ≥ 1.5** | [Download](https://developer.hashicorp.com/terraform/install) or `brew install terraform` |
| **AWS credentials** | `aws configure`, AWS SSO, or environment variables |
| **Netskope REST API v2 token** | Netskope tenant → Settings → Tools → REST API v2 → Generate token (AIG scope) |
| **AIG AMI ID** | Provided by your Netskope account team for your target AWS region |

Set your Netskope credentials as environment variables — never put them in a file:

```bash
export NETSKOPE_SERVER_URL="https://mycompany.goskope.com/api/v2"
export NETSKOPE_API_KEY="your-v2-token"
```

---

## Step 0 — Create the deployment IAM role (first time per AWS account)

The `deployment-role/` template creates a least-privilege IAM role that Terraform uses to deploy AIG resources. Run this once in each AWS account before using any deployment template.

```bash
cd deployment-role
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — add your IAM user or role ARN to trusted_principal_arns
terraform init
terraform apply
```

Then assume the role before running any deployment:

```bash
aws sts assume-role \
  --role-arn "$(terraform -chdir=deployment-role output -raw role_arn)" \
  --role-session-name aig-deploy
# Export the returned credentials as environment variables
```

---

## Deployment guides

Each template has a full step-by-step guide:

- **[New VPC — private subnet](new-vpc-private/README.md)** — recommended for most POVs
- **[New VPC — public subnet](new-vpc-public/README.md)** — quickest path to a working gateway
- **[Existing VPC](existing-vpc/README.md)** — use your own networking

---

## Reference

- [Troubleshooting guide](docs/troubleshooting.md)
- [Terraform state management](docs/state-management.md) — including remote state in S3
