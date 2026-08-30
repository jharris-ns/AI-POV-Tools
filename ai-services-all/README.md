# Netskope AI Services — Combined Stack Deployment

This folder provides a Terraform template that deploys the **Netskope AI Gateway (AIG)**, **AI Guardrails LLM service**, and **DLP On-Demand (DLPoD)** together in a single `terraform apply`. All three services are automatically wired together — no manual registration steps required.

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
  └── NAT Gateway ────────────────────────────────────► repos, Docker Hub, S3, licensing
         │
         ▼
Private subnet (10.0.2.0/24)
  ├── Guardrails GPU EC2 (.10) — LLM content inspection
  └── DLPoD EC2 (.20)          — DLP inspection (TLS, port 443)
```

The AIG, Guardrails, and DLPoD are wired together automatically via a Secrets Manager bootstrap secret. Guardrails and DLPoD must be healthy before the AIG instance is created — readiness gates enforce this ordering during `terraform apply`.

---

## Options

| Option | Directory | Best for |
|--------|-----------|---------|
| [New VPC — public AIG](new-vpc-public/README.md) | `new-vpc-public/` | Full stack (AIG + Guardrails + DLPoD) in a fresh environment |

---

## Prerequisites

| Requirement | How to get it |
|-------------|---------------|
| **Terraform ≥ 1.5** | [Download](https://developer.hashicorp.com/terraform/install) or `brew install terraform` |
| **AWS credentials** | `aws configure`, AWS SSO, or environment variables |
| **GPU instance quota** | EC2 service quota for `g4dn` or `g5` in your target region — AWS console → Service Quotas → EC2 |
| **Netskope REST API v2 token** | Netskope tenant → Settings → Tools → REST API v2 → Generate token (AIG scope) |
| **AIG AMI ID** | Subscribe to the Netskope AI Gateway on AWS Marketplace — AMI ID is region-specific and shown after accepting terms |
| **DLPoD AMI ID** | Obtained from Netskope — region-specific |
| **DLPoD license key** | Obtained from Netskope |
| **S3 bucket with Guardrails image** | Upload `aisecurity-llm.tgz` to an S3 bucket in the same region before running `terraform apply` |

Set Netskope credentials as environment variables — never put them in a tfvars file:

```bash
export NETSKOPE_SERVER_URL="https://mycompany.goskope.com/api/v2"
export NETSKOPE_API_KEY="your-v2-token"
```

---

## Upload the Guardrails image to S3

The Guardrails GPU instance downloads the Docker image from S3 at first boot. Upload it before running `terraform apply`.

```bash
aws s3 mb s3://my-guardrails-bucket --region YOUR_REGION
aws s3 cp aisecurity-llm.tgz s3://my-guardrails-bucket/aisecurity-llm.tgz
```

---

## Deployment guide

- **[New VPC — public AIG, private Guardrails + DLPoD](new-vpc-public/README.md)**

---

## How the services are wired together

Terraform writes a Secrets Manager bootstrap secret containing the AIG enrollment token, the Guardrails host, and the DLPoD TLS configuration:

```json
{
  "bootstrap": true,
  "enrollment_token": "<generated-by-terraform>",
  "ai_guardrails": {
    "host": "http://10.0.2.10:8080/invocations"
  },
  "dlp": {
    "host": "https://dlp.aigw.internal",
    "certificate": "-----BEGIN CERTIFICATE-----\n...\n-----END CERTIFICATE-----\n"
  }
}
```

The AIG reads this secret at first boot and configures both services during enrollment. A Route 53 private hosted zone resolves `dlp.aigw.internal` to the DLPoD private IP within the VPC.

**DLPoD TLS:** Terraform generates a two-tier certificate hierarchy (CA + leaf) and delivers it to DLPoD via EC2 user-data. The CA certificate is embedded in the AIG bootstrap secret so the AIG can verify DLPoD's TLS chain without a public CA.

Both private IPs are pinned in `terraform.tfvars` (`guardrails_private_ip`, `dlpod_private_ip`) so the bootstrap secret can reference them before the instances are created.

---

## Reference

- [New VPC deployment guide](new-vpc-public/docs/deployment.md)
- [Troubleshooting guide](new-vpc-public/docs/troubleshooting.md)
- [DevOps reference](new-vpc-public/docs/devops.md)
- [GPU Guardrails only — existing VPC](../gpu-guardrails/existing-vpc/README.md)
- [GPU Guardrails only — new VPC](../gpu-guardrails/new-vpc-private/README.md)
- [AIG only — all options](../aig/README.md)
