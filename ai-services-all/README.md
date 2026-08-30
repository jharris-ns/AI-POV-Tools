# Netskope AI Services — Combined AIG + GPU Guardrails Deployment

This folder provides a Terraform template that deploys both the **Netskope AI Gateway (AIG)** and the **AI Guardrails LLM service** together in a single `terraform apply`. The AIG is automatically configured to route LLM inspection requests to the Guardrails service — no manual registration step is required.

Use this when you want to stand up the full AI inspection stack in one shot.

---

## What this deploys

```
Internet
    │ (port 443)
    ▼
Internet Gateway
    │
    ▼
Public subnet (10.0.1.0/24)
  ├── AI Gateway EC2 (Elastic IP) ─────────────────────► Netskope Cloud
  └── NAT Gateway ────────────────────────────────────► NVIDIA repos, Docker Hub, S3
         │
         ▼
Private subnet (10.0.2.0/24)
  └── Guardrails GPU EC2 (fixed private IP, no public IP)
         │  S3 image download (via VPC gateway endpoint)
         │  management (via SSM / CloudWatch interface endpoints)
```

The AIG and Guardrails are wired together automatically. The bootstrap secret written by Terraform includes the Guardrails service host — the AIG applies this configuration when it enrolls at first boot.

---

## Options

| Option | Directory | AIG | Guardrails | Best for |
|--------|-----------|-----|-----------|---------|
| [New VPC — public AIG](new-vpc-public/README.md) | `new-vpc-public/` | Public subnet, Elastic IP, internet-accessible | Private subnet, NAT Gateway, no public IP | Full stack in a fresh environment |

---

## Prerequisites

Before deploying you need:

| Requirement | How to get it |
|-------------|---------------|
| **Terraform ≥ 1.5** | [Download](https://developer.hashicorp.com/terraform/install) or `brew install terraform` |
| **AWS credentials** | `aws configure`, AWS SSO, or environment variables |
| **GPU instance quota** | EC2 service quota for g4dn or g5 in your target region — check under AWS console → Service Quotas → EC2 |
| **Netskope REST API v2 token** | Netskope tenant → Settings → Tools → REST API v2 → Generate token (AIG scope) |
| **AIG AMI ID** | Subscribe to the Netskope AI Gateway on AWS Marketplace and accept the terms — the AMI ID is region-specific and shown after subscription |
| **S3 bucket with Guardrails image** | Upload `aisecurity-llm.tgz` to an S3 bucket in the same region before running `terraform apply` |

Set your Netskope credentials as environment variables — never put them in a file:

```bash
export NETSKOPE_SERVER_URL="https://mycompany.goskope.com/api/v2"
export NETSKOPE_API_KEY="your-v2-token"
```

---

## Upload the Guardrails image to S3

The Guardrails GPU instance downloads the Docker image from S3 at first boot. Upload it before running `terraform apply`.

```bash
# Create a bucket (if you don't have one already)
aws s3 mb s3://my-guardrails-bucket --region YOUR_REGION

# Upload the image tarball
aws s3 cp aisecurity-llm.tgz s3://my-guardrails-bucket/aisecurity-llm.tgz
```

---

## Deployment guide

- **[New VPC — public AIG, private Guardrails](new-vpc-public/README.md)**

---

## How the services are wired together

The Terraform template writes a single Secrets Manager bootstrap secret that includes both the AIG enrollment token and the Guardrails configuration:

```json
{
  "bootstrap": true,
  "enrollment_token": "<generated-by-terraform>",
  "ai_guardrails": {
    "host": "http://10.0.2.10:8080/invocations"
  }
}
```

The AIG reads this secret at first boot and applies the `ai_guardrails` block as part of enrollment. No AIGW CLI configuration is required.

The Guardrails private IP is pinned in `terraform.tfvars` (`guardrails_private_ip`, default `10.0.2.10`). This allows the secret to reference the host before the GPU instance is created, avoiding a circular dependency.

---

## Reference

- [New VPC deployment guide](new-vpc-public/README.md)
- [GPU Guardrails only — existing VPC](../gpu-guardrails/existing-vpc/README.md)
- [GPU Guardrails only — new VPC](../gpu-guardrails/new-vpc-private/README.md)
- [AIG only — all options](../aig/README.md)
