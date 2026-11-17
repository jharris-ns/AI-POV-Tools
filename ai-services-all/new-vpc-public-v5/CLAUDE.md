# Deployment Guide — Netskope AI Services (New VPC, v5)

This directory is a single Terraform root that deploys the full Netskope AI Services stack in a new AWS VPC: **AI Gateway (AIG)**, **AI Guardrails** and **DLP On-Demand (DLPoD)**, plus a bastion that finishes the AIG's setup. A Windows 11 VM and a LibreChat instance are optional. Use this guide to walk a user through deployment from scratch.

When a user asks for help deploying here, go through the checklist below step by step and confirm each item before moving on. The repo-wide rules in the root `CLAUDE.md` still apply: secrets only in environment variables, `terraform plan` summarized before `apply`, and an explicit yes before `destroy`.

This is v5 of the combined template. An older `new-vpc-public/` sibling may exist in the source repository; do not recommend it. Variable names, outputs and behavior differ, so do not mix instructions or `terraform.tfvars` files between the two.

---

## What gets deployed

| Component | Subnet | Default type | Notes |
|-----------|--------|--------------|-------|
| AIG | public | `c6a.4xlarge` | Elastic IP, HTTPS on 443 from `aig_allowed_cidr_blocks` |
| AI Guardrails | private | `g4dn.xlarge` | GPU. Port 8080 inside the VPC |
| DLPoD | private | `c5d.4xlarge` | TLS on 443, hostname `dlp.aig.internal` (`dlpod_hostname`) via a Route 53 private zone |
| Bastion | public | `t3.small` | `enable_bastion`, default `true`. Signs and installs the AIG certificate, sets the AIG's DLP and Guardrails hosts, reports `aig-ready`. Do not disable it on a first deployment |
| Windows 11 VM | public | `m5.xlarge` | `enable_win11_vm`, default `false`. Needs the user's own Windows 11 AMI |
| LibreChat | public | `t3.medium` | `enable_librechat`, default `false`. Open registration; only the CIDR list restricts access |

Supporting resources: VPC, NAT gateway, VPC endpoints, Route 53, Secrets Manager, SSM parameters, CloudWatch, a lab root CA (generated locally with `openssl` or supplied), and an SSH key pair.

Timing: about 35–50 minutes end to end. What `terraform apply` itself waits for depends on the four `wait_for_*` variables (all `false` by default). With the defaults, apply returns in minutes, but Guardrails and DLPoD keep booting and the stack is not ready for roughly 30 more minutes (longer with a stock Ubuntu Guardrails image). Do not tell the user the stack is ready when apply returns unless all four are `true`. Check `aig-ready` instead (see Verify).

---

## Pre-flight checklist

Confirm each item before `terraform init`. `../../scripts/preflight.sh ai-services-all/new-vpc-public-v5` (run from the repo root) checks most of them.

### 1. Terraform version
```bash
terraform version
```
Must be **≥ 1.9**. If not, direct the user to https://developer.hashicorp.com/terraform/install.

### 2. Local tools
`openssl` and the `aws` CLI must be on the `PATH` of the machine running Terraform. Both are used by `local-exec` provisioners.

### 3. AWS credentials
```bash
aws sts get-caller-identity
```
Must return a valid account and ARN. To use a named profile, export it (`export AWS_PROFILE=<profile>`) before running Terraform, and run `aws sso login` / `aws login` for it first if it needs that. The provider block in `main.tf` deliberately sets no `profile`: the `aws ssm …` commands in the readiness gates read only the environment, so a profile hard-coded in the provider would leave them with "Unable to locate credentials". If you see a `profile` setting in the provider block, remove it.

The operator's permissions are listed in `docs/iam-permissions.md`.

### 4. GPU instance quota
The target region needs quota for the Guardrails instance type:
- AWS Console → Service Quotas → Amazon EC2 → "Running On-Demand G and VT instances"
- Minimum **4 vCPUs** for `g4dn.xlarge`. `g5.xlarge` is also 4 vCPUs.

### 5. AIG AMI ID
Region-specific and requires accepting AWS Marketplace terms (search "Netskope AI Gateway"). `aig_ami_id` has a default that is valid for one region only (see `variables.tf`). Ask the user for the ID in their region. Never fill in an ID from an example or from another region.

### 6. DLPoD AMI ID
Obtain from Netskope. `dlpod_ami_id` has a default that is valid for one region only (see `variables.tf`). Ask the user for their region and confirm the AMI exists there.

### 7. Guardrails image — one of two options
- **S3 bucket (default path).** Upload `aisecurity-llm.tgz` to a bucket in the **same region** as `aws_region`, then set `guardrails_llm_image_s3_bucket` (and `guardrails_llm_image_s3_key` if the object is not named `aisecurity-llm.tgz`):
  ```bash
  aws s3 cp aisecurity-llm.tgz s3://YOUR_BUCKET_NAME/aisecurity-llm.tgz
  ```
- **Pre-built AMI.** Set `guardrails_ami_id` to an Ubuntu-based AMI that already has the NVIDIA driver, container toolkit, Docker and the LLM image. This is the fast path (about 30 minutes end to end). The bucket is then optional.

At least one must be set, or the plan fails.

### 8. Netskope credentials
Environment variables only. Never in `terraform.tfvars`:
```bash
export NETSKOPE_SERVER_URL="https://mycompany.goskope.com/api/v2"
export NETSKOPE_API_KEY="your-rest-api-v2-token"
```
The server URL is the tenant URL plus `/api/v2`. The token comes from Tenant → Settings → Tools → REST API v2 and needs appliance management permissions.

### 9. DLPoD license key
```bash
export TF_VAR_netskope_onpremappliance_licensekey="your-license-key"
```
The variable is `netskope_onpremappliance_licensekey`, not `dlpod_licensekey` as in the standalone DLPoD templates. Obtain the key from Netskope. It can also go in `terraform.tfvars` (gitignored), but the environment variable is preferred.

### 10. Optional extras
- **Windows 11 VM:** `enable_win11_vm = true` and a `win11_ami_id` the user is licensed for. AWS publishes none. Default tenancy is `dedicated`, which bills extra.
- **LibreChat:** `enable_librechat = true`. Nothing is preconfigured; see the README's LibreChat section.
- **Existing key pairs:** the five `*_key_pair_name` variables are optional. Blank uses the key pair Terraform creates. Do not tell users key pairs are mandatory.

---

## Configure terraform.tfvars

```bash
cp terraform.tfvars.example terraform.tfvars
```

Fill in every value the example marks REQUIRED:

| Variable | Where to get it |
|----------|----------------|
| `aws_tag_owner` | Email of the person responsible. Validated as an email address |
| `aws_tag_purpose` | Free text, no commas (for example `pov`) |
| `aws_tag_terminate_after` | `YYYY-MM-DD`, a real date |
| `aws_region`, `availability_zone` | Ask. The AZ must be in the region: `aws ec2 describe-availability-zones --region YOUR_REGION` |
| `aws_object_unique_prefix` | Lowercase letters, digits, hyphens, 1–20 characters, must not start with `aws` or `ssm`. Prefixes every resource name and the SSM parameter names |
| `aig_netskope_name` | 1–15 characters, unique in the tenant |
| `aig_ami_id` | From AWS Marketplace after accepting terms; set it unless the region matches the default |
| `dlpod_ami_id` | From Netskope; set it unless the region matches the default |
| `guardrails_llm_image_s3_bucket` or `guardrails_ami_id` | See checklist item 7 |

**Allowed CIDRs.** `aig_allowed_cidr_blocks`, `bastion_allowed_cidr_blocks`, `win_allowed_cidr_blocks` and `librechat_allowed_cidr_blocks` all default to `["10.0.0.0/16"]`, so nothing outside the VPC can connect. Ask the user which source addresses should reach the AIG (and the optional instances). Entries must be IPv4 CIDRs with no host bits set; a single host is `/32`. The AIG list was renamed from `allowed_cidr_blocks`. An old tfvars that still uses the old name leaves the AIG at the default, with no error.

**Waits.** Ask whether the user needs the stack working the moment apply finishes. If yes, set all four `wait_for_*` variables to `true`; apply then takes about 30 minutes with a pre-built Guardrails AMI. If no, leave them `false` and have them watch `aig-ready`.

Everything else has a working default.

After the user edits `terraform.tfvars`, never echo the file back if it holds a license key or token.

---

## Deploy

```bash
terraform init
terraform plan
terraform apply
```

1. Run `terraform plan` and summarize it for the user: how many resources, which optional features are on, and the CIDR lists. Then ask before `apply`.
2. Do not interrupt a running `apply`. If a gate times out, see `docs/troubleshooting.md`.
3. If the plan fails validation, the message names the variable. Fix `terraform.tfvars` rather than loosening the validation.

Files Terraform writes to this directory, all gitignored and sensitive. Never print or paste them:

| File | Contents |
|------|----------|
| `my-private-key.pem` | Generated SSH private key (unless `keypair_existing_private_key_local_path` is set) |
| `<prefix>-root-ca-key.pem`, `<prefix>-root-ca-cert.pem` | Lab root CA (unless `ca_existing_signing_*` are set). The cert is public; the key is not |
| `terraform.tfstate*` | Contains TLS private keys, the enrollment token and the license key |

---

## Verify deployment

```bash
terraform output
aws ssm get-parameter --name "/<prefix>/aig-ready" --region <region> --query Parameter.Value --output text
```

`aig-ready` reads `healthy:<AIG instance id>` when the AIG is enrolled, has its certificate, and has its DLP and Guardrails hosts set. Until then it lists which step it is waiting on and the last error. Only the bastion writes it, so it exists only while `enable_bastion` is `true`.

Key outputs:

| Output | Use |
|--------|-----|
| `aig_aws_eip_public_ip` | Address AI clients proxy through, on port 443 |
| `aig_fqdn` | AWS public DNS name of that address; the CN of the AIG certificate |
| `guardrails_ssm_connect_command` | Session Manager into the Guardrails instance |
| `bastion_ssm_connect_command` | Session Manager into the bastion (null without the bastion) |
| `dlp_host_url` | DLP host configured in the AIG, `https://dlp.aig.internal` by default |
| `guardrails_health_check_url` | `http://<guardrails ip>:8080/ping`, reachable only from inside the VPC |
| `nat_gateway_ip` | Outbound address of the private subnet, for firewall allowlists |
| `librechat_url`, `win11_public_ip` | Only with the matching `enable_*` |

---

## Remote state (recommended)

State contains TLS private keys in plaintext. For any deployment that will persist, use S3 with KMS encryption. Create `backend.hcl` from the example in `docs/deployment.md` (there is no `backend.hcl.example` file here; `backend.hcl` is gitignored), then:

```bash
terraform init -backend-config=backend.hcl
```

The bucket and lock table are created as described in `../../aig/docs/state-management.md`.

---

## Troubleshooting

- Diagnostic commands and failure modes: `docs/troubleshooting.md`
- Architecture, bootstrap internals, AIG→DLPoD TLS validation, CI/CD: `docs/devops.md`
- AIG certificate and host setup (bastion script, `aig-ready` format): the "AIG setup and readiness" section of `README.md`

Common first questions:

- **Apply finished but nothing responds.** Expected with the `wait_for_*` defaults. Check `aig-ready`, then the Guardrails logs (`/var/log/user-data.log`, `/var/log/guardrails-phase2.log`) over SSM.
- **AIG enrolled but DLP or Guardrails host not set.** The AIG's Configuration API rejects a host that is not answering yet. The bastion retries until it is. Look at `aig-ready` and `/var/log/aig-cert-setup.log` on the bastion.
- **AIG enrollment token expired.** It lasts 24 hours after apply. Re-apply with the replace commands below.

To rebuild one component without destroying everything:

```bash
# AIG only: new token and new instance (same appliance record)
terraform apply \
  -replace=netskope_aig_appliance_enrollment_token.this \
  -replace=aws_secretsmanager_secret_version.aig_bootstrap \
  -replace=aws_instance.aig
```

Full AIG re-registration, Guardrails and DLPoD rebuilds are in `docs/troubleshooting.md` §Rebuilding Components. If the AIG is replaced while the bastion is disabled, set `enable_bastion = true` first, or the new AIG gets no certificate.

---

## Tear down

Before `terraform destroy`, tell the user what it removes: all AWS resources in this stack (including the bastion and any Windows 11 / LibreChat instances, and every chat and account on LibreChat) and the AIG's Netskope appliance registration. Get an explicit yes first.

```bash
terraform destroy
```

If it hangs for a long time on subnet or VPC deletion, see `docs/troubleshooting.md` §terraform destroy Issues (VPC endpoint network interfaces).
