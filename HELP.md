# Help — Netskope POV Deployment Toolkit

Start here if you have never used this repository. It answers "I want to…"
questions and points you to the right guide. For the module overview see
[`README.md`](README.md).

If you use **Claude Code**, open this folder and ask it anything. It reads
`CLAUDE.md` for context and offers these commands:

| Command | What it does |
|---------|--------------|
| `/pov-preflight` | Checks Terraform, AWS credentials, quotas, key pairs and env vars for the template you chose |
| `/pov-deploy` | Walks you through tfvars, `init`, `plan`, `apply`, outputs and verification |
| `/pov-troubleshoot` | Systematic diagnosis of a failed or unhealthy deployment |
| `/pov-teardown` | Safe `terraform destroy` with the right ordering and reminders |
| `/pov-curate` | *Netskope SEs only* — builds a customer-specific package |

Without Claude Code, `scripts/preflight.sh <template-dir>` runs the same
readiness checks from the shell.

---

## I want to…

### …figure out which template to use

```
Which components?
├── AIG + Guardrails + DLPoD → ai-services-all/new-vpc-public/   ← recommended
│     One apply, one state, DNS/TLS between components wired for you.
└── One component only, or you specifically want one-at-a-time → pick the component:
      AIG        → aig/            (existing-vpc | new-vpc-public | new-vpc-private)
      Guardrails → gpu-guardrails/ (existing-vpc | new-vpc-private)
      DLPoD      → dlpod/          (existing-vpc | new-vpc-private)

Existing VPC and subnet?  → existing-vpc/
New VPC, AIG must be reachable from the internet? → aig/new-vpc-public/
New VPC, private only → new-vpc-private/   (recommended for a realistic POV)
```

Guardrails and DLPoD never get a public option — they are back-end services
the AIG talks to privately.

Each module README has the same decision tree with more detail:
[`aig/README.md`](aig/README.md) ·
[`gpu-guardrails/README.md`](gpu-guardrails/README.md) ·
[`dlpod/README.md`](dlpod/README.md) ·
[`ai-services-all/README.md`](ai-services-all/README.md)

### …deploy the components one at a time (staged build)

The **recommended** way to get all three appliances is the combined
[`ai-services-all/new-vpc-public/`](ai-services-all/new-vpc-public/README.md)
stack: one apply, one state, and the DNS/TLS wiring between them is done for
you. Use the staged build below only if you do not want the combined stack
and prefer to deploy each appliance as its own Terraform run. Keep all three
in one VPC: Stage 1 creates it, Stages 2–3 join it.

```
Stage 1: gpu-guardrails/new-vpc-private/  creates the VPC; outputs vpc_id, private_subnet_id,
                                          vpc_cidr, private_subnet_cidr, ai_guardrails_host
Stage 2: dlpod/existing-vpc/              joins it; outputs dlp_host, ca_cert_pem
Stage 3: aig/existing-vpc/                joins it; takes guardrails_host, dlp_host, dlp_ca_cert_pem
```

The AIG must be last: it reads its bootstrap secret once at first boot, and
that secret has to contain the Guardrails and DLPoD endpoints plus the DLPoD
CA certificate — none of which exist until Stages 1 and 2 have run.
Variable-by-variable instructions:
[`ai-services-all/README.md`](ai-services-all/README.md) §Staged build.

### …check I have everything before I start

Run `scripts/preflight.sh <template-dir>` or `/pov-preflight`. It checks
the items below and tells you which README section fixes each failure.

| Need | Templates | Where to get it |
|------|-----------|-----------------|
| Terraform ≥ 1.5 | all | [terraform.io/install](https://developer.hashicorp.com/terraform/install) |
| AWS CLI profile | all | [AWS CLI quickstart](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html) |
| EC2 key pair(s) in the region | all | `aws ec2 describe-key-pairs --region …` |
| Netskope REST API v2 token + tenant URL | AIG, combined | Tenant → Settings → Tools → REST API v2 |
| AIG AMI ID | AIG, combined | AWS Marketplace → Netskope AI Gateway → accept terms; region-specific |
| DLPoD AMI ID | DLPoD, combined | From Netskope; region-specific. Templates include a lookup map for some regions |
| DLPoD license key | DLPoD, combined | From Netskope |
| `aisecurity-llm.tgz` in an S3 bucket in the region | Guardrails, combined | From Netskope; `aws s3 cp` it before apply |
| EC2 quota "Running On-Demand G and VT instances" ≥ 4 vCPU | Guardrails, combined | AWS Console → Service Quotas → EC2 |
| Deployment IAM role applied | AIG | `aig/deployment-role/`, once per account |

### …set my credentials safely

Environment variables, never files:

```bash
export NETSKOPE_SERVER_URL="https://<tenant>.goskope.com/api/v2"
export NETSKOPE_API_KEY="<rest-api-v2-token>"
export TF_VAR_dlpod_licensekey="<license>"   # any template that deploys DLPoD
```

`terraform.tfvars` is gitignored, but anything in it ends up in
`terraform.tfstate`. State already holds TLS private keys, so treat it as a
secret and consider remote encrypted state:
[`aig/docs/state-management.md`](aig/docs/state-management.md).

### …deploy

1. `cd` into the template directory (never a module's top level).
2. `cp terraform.tfvars.example terraform.tfvars` and fill in the REQUIRED
   values listed in that directory's README.
3. `terraform init`, `terraform plan`, `terraform apply`.

How long it takes:

| Template | `apply` returns | Service usable |
|----------|-----------------|----------------|
| AIG | 3–5 min | allow up to 15 min for boot and self-enrollment |
| Guardrails | ~2 min | 15–35 min later (two-phase boot with a reboot) |
| DLPoD | a few minutes | after `nsbootstrap` completes, ~5–10 min |
| Combined stack | 35–50 min (blocks on readiness gates) | when apply finishes |

### …know whether it worked

| Component | Check |
|-----------|-------|
| AIG | Netskope tenant shows the appliance **connected**; or `GET /api/v2/aig/appliances` |
| Guardrails | `curl http://<private-ip>:8080/ping` → `{"status":"Healthy"}` from inside the VPC |
| DLPoD | Bootstrap status commands in [`dlpod/README.md`](dlpod/README.md) §Verifying bootstrap |
| Combined | `terraform output` and the per-component checks above |

### …fix something

| Symptom | Guide |
|---------|-------|
| AIG shows Disconnected / never enrolls / token expired / provider auth error | [`aig/docs/troubleshooting.md`](aig/docs/troubleshooting.md) |
| Guardrails Phase 1 or 2 stalled, health check failing, SSM readiness stale | [`ai-services-all/new-vpc-public/docs/troubleshooting.md`](ai-services-all/new-vpc-public/docs/troubleshooting.md) §Guardrails |
| DLPoD bootstrap not applied, TLS errors, AIG cannot reach DLPoD | same guide, §DLPoD; and [`dlpod/README.md`](dlpod/README.md) §Known issues |
| `terraform destroy` hangs on subnet/VPC | same guide (VPC endpoint ENIs) |
| Access denied during apply | [`aig/docs/iam-permissions.md`](aig/docs/iam-permissions.md) — name prefixes must match |
| State lock / corrupted state | [`aig/docs/state-management.md`](aig/docs/state-management.md) |

Or run `/pov-troubleshoot`.

### …remove everything

`terraform destroy` in each template directory, in reverse order for staged
builds (AIG → DLPoD → Guardrails). AIG templates also remove the appliance
from the Netskope tenant. The S3 image bucket and any remote-state bucket
are not managed by these templates. `/pov-teardown` walks through it.

### …understand how it works under the hood

- AIG bootstrap via Secrets Manager: [`aig/README.md`](aig/README.md) §Bootstrap process
- DLPoD zero-touch provisioning and `bootstrap.json` schema: [`dlpod/README.md`](dlpod/README.md)
- Guardrails two-phase boot: [`gpu-guardrails/README.md`](gpu-guardrails/README.md) §Setup process
- Combined stack internals, TLS validation, CI/CD: [`ai-services-all/new-vpc-public/docs/devops.md`](ai-services-all/new-vpc-public/docs/devops.md)
- Design decisions and constraints per module: the `CLAUDE.md` in each module directory (written for Claude, readable by humans)

### …run the tests

[`aig/tests/README.md`](aig/tests/README.md) — static tests with mock
providers (no credentials, ~30 s) and integration tests that deploy and
destroy real infrastructure. `dlpod/new-vpc-private/tests/` has a
`terraform test` file.

### …build a package for a customer (Netskope SEs)

Run `/pov-curate` in Claude Code, or directly:

```bash
scripts/curate.sh --customer acme --modules aig/new-vpc-private,gpu-guardrails/existing-vpc --region us-east-1 --zip
```

Output goes to `dist/acme-<date>/` with a `MANIFEST.md` listing what was
included and the result of a secret scan. See `CLAUDE.md` §Curating a
customer package for the rules.

---

## FAQ

**Why does the AIG template need a Netskope API token but Guardrails and
DLPoD don't?** The AIG is registered in the tenant by Terraform before the
instance boots, so the enrollment token can be placed in Secrets Manager.
Guardrails and DLPoD are configured locally and then pointed at by the AIG.

**Can I put the API key in `terraform.tfvars` since it's gitignored?**
Don't. It would be written into `terraform.tfstate`, which you may later
move to S3 or share. Use the environment variable.

**The example AMI ID didn't work.** AMI IDs are per region. The AIG AMI is
shown in AWS Marketplace after you accept the terms; the DLPoD AMI comes
from Netskope. Some DLPoD templates carry a region → AMI map, but it only
covers the regions Netskope had published at the time.

**`terraform apply` finished but Guardrails isn't responding.** Expected.
Apply returns when EC2 exists; the service needs 15–35 more minutes. Use the
`ssm_connect_command` output and `tail -f /var/log/user-data.log`, then
`/var/log/guardrails-phase2.log`.

**Why does the AIG connect to DLPoD by hostname instead of IP?** The AIG's
TLS client verifies the hostname against the certificate's DNS SANs; an IP
URL fails even with an IP SAN. `dlpod/existing-vpc/` and the combined stack
create a Route 53 private zone for `dlp.aigw.internal`. `dlpod/new-vpc-private/`
does not — set `system_hostname` and provide resolution yourself.

**My appliance name was rejected.** Netskope limits appliance names to 15
characters. The AIG deployment role also expects names starting `aig-`.

**Does `terraform destroy` remove the Netskope registration?** Yes for AIG
templates — the appliance and enrollment token are Terraform resources.

**Is the Secrets Manager secret recoverable after destroy?** No.
`recovery_window_in_days = 0` is set so destroy/apply cycles can reuse the
name. Fine for a POV; change it for production.

---

## Glossary

| Term | Meaning |
|------|---------|
| **AIG / AIGW** | Netskope AI Gateway — the appliance that proxies AI traffic and applies policy |
| **AI Guardrails** | LLM-based content inspection service the AIG calls; runs on a GPU instance |
| **DLPoD** | DLP On-Demand — Netskope data loss prevention inspection appliance |
| **ZTP** | Zero-touch provisioning — DLPoD configures itself from `bootstrap.json` in EC2 user-data |
| **Bootstrap secret** | Secrets Manager JSON the AIG reads at first boot; contains the enrollment token and optional `dlp` / `ai_guardrails` blocks |
| **Enrollment token** | 24-hour token that lets the AIG register with the Netskope tenant |
| **Persona** | DLPoD operating mode: `dlp-on-demand` or `dspm` |
| **Staged build** | Fallback to the combined stack: deploying Guardrails, DLPoD and AIG as separate Terraform runs into one VPC |
| **Template / root** | A directory you run `terraform` in (`existing-vpc/`, `new-vpc-public/`, `new-vpc-private/`) |
| **Deployment role** | Least-privilege IAM role created by `aig/deployment-role/` for the person running Terraform |
| **Instance profile** | IAM role attached to the EC2 instance itself (reads the bootstrap secret; pulls the Guardrails image) |
| **SSM** | AWS Systems Manager Session Manager — shell access without SSH or open ports |
| **Phase 1 / Phase 2** | Guardrails boot stages: NVIDIA driver + reboot, then Docker + container |
| **Readiness gate** | A step in the combined-stack apply that waits for a component to report healthy |
| **Remote state** | `terraform.tfstate` stored in S3 with KMS encryption and DynamoDB locking |
