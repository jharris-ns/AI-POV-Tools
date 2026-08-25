# AIG Terraform Template — Regression Tests

This directory contains two layers of automated tests for the three AIG deployment templates.

| Layer | What it tests | Credentials needed | Time |
|-------|--------------|-------------------|------|
| Layer 1 — static | Terraform plan with mock providers | None | ~30 seconds |
| Layer 2 — integration | Real AWS deployment + Netskope enrollment | AWS + Netskope | ~10–15 minutes |

---

## Prerequisites

- Python 3.9 or later
- Terraform ≥ 1.5
- AWS credentials (Layer 2 only)
- Netskope API credentials (Layer 2 enrollment test only)

Install Python dependencies:

```bash
cd aig/tests
pip install -r requirements.txt
```

---

## Layer 1 — Static tests (no credentials required)

Runs `terraform plan` against the `new-vpc-private` template using mock providers. No real AWS or Netskope calls are made. Use this to validate configuration changes quickly.

```bash
make test-static
```

---

## Layer 2 — Integration tests (real AWS deployment)

Deploys the template to AWS, runs assertions against live resources, then destroys everything. Infrastructure is always destroyed at the end — even if tests fail.

### Required environment variables

```bash
# AWS credentials (choose one method)
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."   # if using temporary credentials
# OR
export AWS_PROFILE="your-profile"

# Netskope credentials (required for enrollment test)
export NETSKOPE_SERVER_URL="https://mycompany.goskope.com/api/v2"
export NETSKOPE_API_KEY="your-v2-api-token"
```

### Run tests for each template

**new-vpc-private** (private subnet + NAT gateway):
```bash
make test-integration
```

**new-vpc-public** (public subnet + Elastic IP):
```bash
make test-integration-public
```

**existing-vpc** (deploys a minimal test VPC first, then the template into it):
```bash
make test-integration-existing
```

**All three templates:**
```bash
make test-all           # Layer 1 + new-vpc-private integration
make test-integration
make test-integration-public
make test-integration-existing
```

---

## Optional overrides

| Variable | Default | Description |
|----------|---------|-------------|
| `AWS_REGION` | `us-west-1` | AWS region to deploy the test stack into |
| `AMI_ID` | _(variable default)_ | Override the AIG AMI ID |
| `APPLIANCE_NAME` | `aig-test` | Appliance name used in all resource Name tags |
| `SKIP_ENROLLMENT` | _(unset)_ | Set to `1` to skip the Netskope enrollment poll (useful when testing with a non-AIG AMI) |

Example — run in a different region with a different AMI:

```bash
make test-integration AWS_REGION=us-east-1 AMI_ID=ami-0123456789abcdef0
```

---

## What each test suite covers

### new-vpc-private (21 tests)

| Class | Tests |
|-------|-------|
| `TestVPC` | VPC exists, correct CIDR, DNS support enabled, DNS hostnames enabled |
| `TestSubnets` | Public subnet CIDR, private subnet CIDR, NAT gateway in public subnet, EC2 in private subnet |
| `TestRouteTables` | Public RT points to IGW, private RT points to NAT gateway |
| `TestSecurityGroup` | Ingress allows TCP 443, egress allows all traffic |
| `TestIAM` | Role trusts EC2, inline policy grants `GetSecretValue` on the bootstrap secret |
| `TestSecretsManager` | Secret exists, contains valid enrollment token |
| `TestEC2Instance` | Instance running, fixed private IP, correct IAM profile, valid AMI |
| `TestNetskopeEnrollment` | Appliance reaches `status=connected` within 15 minutes |

### new-vpc-public (21 tests)

| Class | Tests |
|-------|-------|
| `TestVPC` | VPC exists, correct CIDR, DNS support, DNS hostnames |
| `TestSubnet` | Public subnet CIDR, EC2 in public subnet, no private subnet exists |
| `TestRouteTable` | Route table points to IGW |
| `TestElasticIP` | EIP exists and is associated with the AIG instance |
| `TestSecurityGroup` | Ingress allows TCP 443, egress allows all traffic |
| `TestIAM` | Role trusts EC2, inline policy grants `GetSecretValue` |
| `TestSecretsManager` | Secret exists, contains valid enrollment token |
| `TestEC2Instance` | Instance running, public IP matches EIP output, correct IAM profile, valid AMI, key pair set |
| `TestNetskopeEnrollment` | Appliance reaches `status=connected` within 15 minutes |

### existing-vpc (13 tests)

| Class | Tests |
|-------|-------|
| `TestSecurityGroup` | Ingress allows TCP 443, egress allows all traffic |
| `TestIAM` | Role trusts EC2, inline policy grants `GetSecretValue` |
| `TestSecretsManager` | Secret exists, contains valid enrollment token |
| `TestEC2Instance` | Instance running, private IP matches output, correct subnet, correct IAM profile, valid AMI, key pair set |
| `TestNetskopeEnrollment` | Appliance reaches `status=connected` within 15 minutes |

---

## Test results

JSON reports are written to the tests directory after each run:

| File | Template |
|------|---------|
| `test-results.json` | new-vpc-private |
| `test-results-public.json` | new-vpc-public |
| `test-results-existing.json` | existing-vpc |

---

## Cleanup

If a test run is interrupted before destroy completes, clean up manually:

```bash
make clean                          # destroy new-vpc-private stack
terraform -chdir=../new-vpc-public destroy -auto-approve \
  -var-file=../new-vpc-public/tests/fixtures/new-vpc-public.tfvars
terraform -chdir=../existing-vpc destroy -auto-approve \
  -var-file=../existing-vpc/tests/fixtures/existing-vpc.tfvars \
  -var="vpc_id=FILL_IN" -var="subnet_id=FILL_IN" -var="appliance_host=FILL_IN"
```

If Terraform reports a state lock, force-unlock it:
```bash
terraform -chdir=../new-vpc-private force-unlock LOCK_ID
```
