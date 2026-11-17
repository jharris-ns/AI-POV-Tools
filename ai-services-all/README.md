# Netskope AI Services — Combined Stack

Deploy the **AI Gateway (AIG)**, **AI Guardrails**, and **DLP On-Demand (DLPoD)** together in a single `terraform apply`. **This is the recommended way to deploy the full stack for a POV** — one state file, readiness gates between components, and the Route 53 / TLS wiring between the AIG and DLPoD handled for you.

If the combined stack is not wanted and the customer prefers to deploy one component at a time, use the standalone templates in the order described in [`STAGED-BUILD.md`](../STAGED-BUILD.md).

## Available templates

| Option | Directory | Best for |
|--------|-----------|---------|
| [New VPC — public AIG](new-vpc-public-v5/README.md) | `new-vpc-public-v5/` | Full stack in a fresh AWS environment; AIG with public Elastic IP |

## Previous version

`new-vpc-public/` is the earlier version of this template. It is kept for reference only. Use `new-vpc-public-v5/`: it adds the lab-CA certificate setup, the bastion readiness checks, the optional Windows 11 VM and LibreChat, and mandatory AWS tags. Variable names and outputs differ between the two, so do not mix instructions or `terraform.tfvars` files.

## Deploying one component at a time instead

If the combined stack is not wanted and the customer prefers to install Guardrails, DLPoD and the AIG as three separate Terraform runs, follow [`STAGED-BUILD.md`](../STAGED-BUILD.md) at the repository root. It explains why the order is fixed and maps every output to the input that consumes it.

## Reference

- [Full-stack deployment guide](new-vpc-public-v5/README.md)
- [Troubleshooting guide](new-vpc-public-v5/docs/troubleshooting.md)
- [DevOps reference](new-vpc-public-v5/docs/devops.md)
- [Remote state](new-vpc-public-v5/docs/deployment.md)
- [Deployer IAM permissions](new-vpc-public-v5/docs/iam-permissions.md)
