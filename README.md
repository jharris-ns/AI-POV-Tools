# Netskope POV Deployment Toolkit

This repository contains Terraform templates and supporting documentation for deploying Netskope appliances in proof-of-value (POV) environments on AWS. Each module is designed for fast, repeatable, unattended deployment — no manual console or SSH steps required.

---

## Modules

### AI Gateway (AIG) — Available now

The AI Gateway inspects and controls AI traffic, providing visibility and policy enforcement for generative AI tools such as ChatGPT, Copilot, and custom LLM applications.

Three deployment options are provided, covering the most common network topologies encountered in POVs:

| Option | Directory | Best for |
|--------|-----------|---------|
| [Existing VPC](aig/existing-vpc/README.md) | `aig/existing-vpc/` | You already have a VPC and subnet in AWS |
| [New VPC — public subnet](aig/new-vpc-public/README.md) | `aig/new-vpc-public/` | Fastest setup; gateway directly reachable from the internet |
| [New VPC — private subnet](aig/new-vpc-private/README.md) | `aig/new-vpc-private/` | Production-like; no inbound internet exposure, outbound via NAT |

The gateway self-enrolls at first boot using an enrollment token stored in AWS Secrets Manager — no interactive steps required after `terraform apply`.

**Start here:** [aig/README.md](aig/README.md)

---

### DLP On-Demand (DLPoD) — Coming soon

DLPoD provides cloud-delivered data loss prevention inspection. Standalone DLPoD deployment templates and combined AIG + DLPoD templates will be added to this toolkit once the new DLPoD Zero-Touch Provisioning (ZTP) bootstrap support reaches general availability.

ZTP allows the DLPoD appliance to self-configure at first boot from a structured JSON payload delivered via cloud-init user-data — the same pattern used by AIG today. The `bootstrap.json` schema, platform delivery instructions, and field-level documentation are available now in anticipation of the Terraform templates:

**Reference:** [dlpod/README.md](dlpod/README.md)

---

## Repository structure

```
AI-POV-Tools/
  README.md                  # This file — project overview and navigation
  aig/                       # AI Gateway Terraform templates
    README.md                # AIG overview and template selection guide
    deployment-role/         # Run once: least-privilege IAM role for deployment
    existing-vpc/            # AIG in an existing VPC and subnet
    new-vpc-public/          # AIG in a new VPC with a public subnet and EIP
    new-vpc-private/         # AIG in a new VPC with a private subnet and NAT GW
    tests/                   # Automated regression tests (Layer 1 + Layer 2)
    docs/                    # Troubleshooting and state management guides
  dlpod/
    README.md                # DLPoD ZTP bootstrap reference (templates coming soon)
  docs/                      # Source PDFs and reference documents
```

---

## Common prerequisites

Both AIG and DLPoD deployments require:

- **Terraform >= 1.5** — [install](https://developer.hashicorp.com/terraform/install) or `brew install terraform`
- **AWS credentials** — `aws configure`, AWS SSO, or environment variables
- **Netskope REST API v2 token** — Netskope tenant → Settings → Tools → REST API v2

See the module-specific README for additional requirements.
