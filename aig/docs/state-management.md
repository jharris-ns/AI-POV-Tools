# Terraform State Management

Terraform tracks every resource it has created in a **state file** (`terraform.tfstate`). Understanding state is important for:

- Running `terraform apply` and `terraform destroy` reliably
- Allowing multiple people to work on the same deployment
- Recovering from interrupted operations

---

## Local state (default)

By default Terraform writes state to `terraform.tfstate` in the template directory. This is the simplest option and works fine for a solo POV where only one person runs Terraform commands.

**Limitations of local state:**
- If you lose the file, Terraform loses track of what it deployed (you must clean up manually in AWS and Netskope)
- Only one person can run Terraform at a time
- The state file may contain sensitive values — do not commit it to version control

**Protect your local state file:**
```bash
# Add to .gitignore
echo "terraform.tfstate" >> .gitignore
echo "terraform.tfstate.backup" >> .gitignore
```

---

## Remote state in Amazon S3 (recommended for team use)

Storing state in S3 gives you:
- **Durability** — S3 is not lost when your laptop breaks
- **Sharing** — anyone with S3 access can run Terraform commands
- **Locking** — a DynamoDB table prevents two people running `terraform apply` at the same time

### Step 1 — Create the S3 bucket and DynamoDB table

Run this once. Replace the placeholder values:

```bash
# Create the bucket (versioning is important — it lets you recover old state)
aws s3api create-bucket \
  --bucket my-aig-terraform-state \
  --region us-west-1 \
  --create-bucket-configuration LocationConstraint=us-west-1

aws s3api put-bucket-versioning \
  --bucket my-aig-terraform-state \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket my-aig-terraform-state \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'

# Create the DynamoDB table for state locking (optional but strongly recommended)
aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-west-1
```

### Step 2 — Create a backend configuration file

In the template directory (e.g. `new-vpc-private/`), copy the example:

```bash
cp backend.hcl.example backend.hcl
```

Edit `backend.hcl` and fill in your values:

```hcl
bucket         = "my-aig-terraform-state"
key            = "aig/new-vpc-private/terraform.tfstate"
region         = "us-west-1"
encrypt        = true
dynamodb_table = "terraform-state-lock"
```

> **Key naming convention:** Use a unique key per deployment. If you deploy the same template twice in different regions or with different appliance names, use a different key (e.g. `aig/new-vpc-private-prod/terraform.tfstate`).

### Step 3 — Initialise with the backend config

```bash
terraform init -backend-config=backend.hcl
```

Terraform will ask if you want to migrate existing local state to S3. Type `yes`.

### Step 4 — All subsequent commands work normally

```bash
terraform apply
terraform destroy
```

State is automatically read from and written to S3.

---

## Migrating from local to remote state

If you already have a deployed stack with local state and want to move to S3:

1. Complete steps 1–3 above
2. When `terraform init` asks `Do you want to copy existing state to the new backend?`, answer **yes**
3. Verify the state was copied: `terraform state list`
4. Delete the local state file: `rm terraform.tfstate terraform.tfstate.backup`

---

## Recovering from a corrupted or missing state file

If you lose the state file for a running deployment, you have two options:

**Option A — Destroy resources manually**

Use the AWS console and Netskope UI to manually delete all resources that Terraform created (EC2 instance, security group, IAM role/profile, Secrets Manager secret, NAT gateway, subnets, VPC, Netskope appliance). This is tedious but safe.

**Option B — Re-import resources into a fresh state**

This is advanced. See the [Terraform import documentation](https://developer.hashicorp.com/terraform/cli/import) for details. Each resource type has its own import syntax.

---

## State locking

When Terraform runs, it acquires a lock to prevent concurrent modifications. If a `terraform apply` or `terraform destroy` is interrupted (e.g. by closing the terminal), the lock may not be released.

**Check for and release a stuck lock:**
```bash
terraform force-unlock LOCK_ID
```

The lock ID appears in the error message when Terraform fails to acquire a lock. With a DynamoDB table, you can also see and delete the lock record directly:

```bash
aws dynamodb scan --table-name terraform-state-lock --region us-west-1
```

---

## State file security

The Terraform state file contains sensitive values including the Secrets Manager secret ARN and potentially enrollment token data.

- Never commit `terraform.tfstate` to version control
- When using S3, enable bucket encryption (done in Step 1 above)
- Restrict S3 bucket access using IAM policies — only the people who run Terraform should have access
- Enable S3 access logging to audit who reads and writes the state
