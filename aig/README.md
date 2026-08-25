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
| **AIG AMI ID** | Subscribe to the Netskope AI Gateway on AWS Marketplace and accept the terms — the AMI ID is region-specific and shown after subscription |

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

## Bootstrap process

The Terraform templates in this project automate the AIG bootstrap end-to-end. This section explains how the mechanism works so you can understand what Terraform is building and troubleshoot if something goes wrong.

### How it works

At first boot the AIG appliance:

1. Reads the EC2 **User data** field, which contains a JSON pointer to an AWS Secrets Manager secret.
2. Uses the attached **IAM instance profile** to retrieve that secret — no static credentials needed.
3. Reads the `enrollment_token` from the secret and calls the Netskope control plane to complete enrollment automatically.
4. If optional `dlp` or `ai_guardrails` blocks are present in the secret, applies that configuration immediately after enrollment.

No SSH access or interactive CLI steps are required.

> **What Terraform does:** The templates pre-register the AIG appliance in Netskope (obtaining the `enrollment_token`), create the Secrets Manager secret containing the token, create the IAM role and instance profile, and launch the EC2 instance with the User data pointer — in the correct dependency order. The appliance enrolls itself on first boot.

### EC2 User data

The User data field on the EC2 instance is a small JSON object that tells the appliance where to find its bootstrap secret:

```json
{"bootstrap_secret": "aig/prod/bootstrap"}
```

The value is the secret **name** or full **ARN**. The Terraform templates set this automatically from the `secret_name` variable.

### Bootstrap secret schema

The Secrets Manager secret is a JSON object. The two required fields are always present; the optional blocks are added only when you need those features.

#### Required fields

| Field | Type | Notes |
|-------|------|-------|
| `bootstrap` | bool | Must be `true` — signals the appliance to use the automated bootstrap path |
| `enrollment_token` | string | Enrollment token generated by Netskope when the appliance is pre-registered. **24-hour TTL** — if the instance has not booted within 24 hours, run `terraform apply` again to regenerate the token. |

Minimum valid secret:

```json
{
  "bootstrap": true,
  "enrollment_token": "<token>"
}
```

#### Optional: DLP On-Demand (`dlp`)

Connect the AIG appliance to an existing DLP On-Demand (DLPoD) service for inline DLP inspection. Both fields are required together if the block is present.

| Field | Type | Notes |
|-------|------|-------|
| `certificate` | PEM string | TLS certificate of the DLPoD service. |
| `host` | string | URL of the DLPoD service (e.g. `https://dlp.company.internal`). |

```json
{
  "bootstrap": true,
  "enrollment_token": "<token>",
  "dlp": {
    "certificate": "-----BEGIN CERTIFICATE-----\n<DLP SERVICE CERT PEM>\n-----END CERTIFICATE-----\n",
    "host": "https://dlp.company.internal"
  }
}
```

> If DLP configuration fails, enrollment is unaffected. Re-apply the DLP configuration after the instance is enrolled.

#### Optional: AI Guardrails (`ai_guardrails`)

Configure an LLM backend for AI Guardrails inspection. Only `host` is required; add the remaining fields if your LLM backend requires TLS certificate validation or token-based authentication.

| Field | Type | Notes |
|-------|------|-------|
| `host` | string | Required. URL of the LLM inference endpoint (e.g. `https://<llm-endpoint>/invocations`). |
| `certificate` | PEM string | TLS certificate of the LLM backend (optional). |
| `jwt_url` | string | OAuth2 token endpoint for token-based auth (optional). |
| `client_id` | string | OAuth2 client ID (optional). |
| `client_secret` | string | OAuth2 client secret (optional). |
| `scope` | string | OAuth2 scope (optional). |

```json
{
  "bootstrap": true,
  "enrollment_token": "<token>",
  "ai_guardrails": {
    "host": "https://<llm-endpoint>/invocations",
    "certificate": "-----BEGIN CERTIFICATE-----\n<LLM CERT PEM>\n-----END CERTIFICATE-----\n",
    "jwt_url": "https://<auth-provider>/oauth2/token",
    "client_id": "<client-id>",
    "client_secret": "<client-secret>",
    "scope": "<scope>"
  }
}
```

> If AI Guardrails configuration fails, enrollment is unaffected. Re-apply the configuration after the instance is enrolled.

### Verifying enrollment

After `terraform apply` completes and the instance has booted, confirm enrollment via either method:

**Netskope UI:** Go to **Settings > Security Cloud Platform > VM Onboarding**. A green icon next to the appliance name in the VM-Name column confirms successful enrollment.

**REST API:**

```bash
curl -s -H "Netskope-Api-Token: $NETSKOPE_API_KEY" \
  "$NETSKOPE_SERVER_URL/aig/appliances" | jq '.elements[] | {name, status}'
```

| `status` | Meaning |
|----------|---------|
| `connected` | Enrolled and healthy — heartbeat received within the last 30 minutes |
| `not-registered` | Enrollment has not completed |
| `disconnected` | Enrolled, but no heartbeat in the last 30 minutes |

A status of `connected` confirms the appliance is enrolled and reporting.

### Enrollment token TTL and re-enrollment

The enrollment token expires **24 hours** after it is generated. If the instance has not enrolled before expiry:

```bash
terraform apply   # generates and stores a fresh token; the instance picks it up at next boot
```

The token resource (`netskope_aig_appliance_enrollment_token`) is replace-on-apply — re-running `apply` is the correct and only supported way to refresh it.

---

## Reference

- [Troubleshooting guide](docs/troubleshooting.md)
- [Terraform state management](docs/state-management.md) — including remote state in S3
