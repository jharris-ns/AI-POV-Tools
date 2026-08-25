# CLAUDE.md — AI Gateway Terraform Templates

This file provides context for Claude Code when assisting users with these templates.

## What this project does

Deploys a Netskope AI Gateway (AIG) appliance on AWS EC2 using automated
Secrets Manager bootstrap. The appliance self-enrolls at first boot — no SSH
or manual CLI required. Three deployment options share identical Netskope,
IAM, and Secrets Manager logic; only the networking layer differs.

## Directory structure

```
terraform/aig/
  README.md               # User-facing getting started guide
  CLAUDE.md               # This file
  main.tf                 # Comment-only redirect — not a Terraform root
  deployment-role/        # Run first: creates the IAM role needed to deploy
  existing-vpc/           # Option 1: bring your own VPC and subnet
  new-vpc-public/         # Option 2: new VPC, AIG in public subnet with EIP
  new-vpc-private/        # Option 3: new VPC, AIG in private subnet + NAT GW
```

Each subdirectory is a self-contained Terraform root with its own
`main.tf`, `variables.tf`, `outputs.tf`, and `terraform.tfvars.example`.

## Helping a user choose an option

Ask or infer from context:

1. **Do they have an existing VPC?**
   - Yes → `existing-vpc/`

2. **Do they need the AIG reachable from the internet, or just from within AWS/VPN?**
   - Internet / quickest demo → `new-vpc-public/`
   - Internal / more production-like → `new-vpc-private/`

The `new-vpc-private/` option is the most complete and is the recommended
default for a real POV. `new-vpc-public/` has the simplest tfvars.

## Key design decisions (understand before changing)

### Fixed private IP (`aig_private_ip`) in `new-vpc-private`
Terraform must register the AIG appliance in Netskope (`netskope_aig_appliance`)
before the EC2 instance exists, because the enrollment token depends on the
appliance ID. The `host` field on that resource requires a known address.
Pinning a private IP on the EC2 instance via `private_ip = var.aig_private_ip`
makes the address deterministic at plan time. Do not remove this without an
alternative solution to the ordering problem.

### EIP allocated before EC2 in `new-vpc-public`
Same ordering problem solved differently: an Elastic IP is allocated first,
its `public_ip` is used as the appliance `host`, and the EIP is associated
with the instance after creation.

### `appliance_host` variable in `existing-vpc`
In the existing-VPC case there is no infrastructure Terraform controls that
gives a predictable address before EC2 creation. The user provides the expected
IP or hostname as a variable. The AIG still self-enrolls via the token — the
`host` field is used for display in the Netskope UI, not for the enrollment
handshake itself.

### Inline IAM policy (not managed policy)
The IAM policy granting `secretsmanager:GetSecretValue` is an inline role
policy (`aws_iam_role_policy`) rather than a standalone managed policy
(`aws_iam_policy` + `aws_iam_role_policy_attachment`). This keeps the
permission coupled to the role — deleting the role deletes the policy.
Correct for a scoped POV deployment; a shared policy would be appropriate
only if multiple roles needed access.

### `recovery_window_in_days = 0` on the secret
Allows `terraform destroy` / `terraform apply` cycles to reuse the same
secret name without the 7-day AWS deletion delay. Appropriate for a POV;
flag this for production hardening.

### Provider credentials
The `netskopeoss/netskope` provider reads `NETSKOPE_SERVER_URL` and
`NETSKOPE_API_KEY` from environment variables. The provider block also
accepts `server_url` and `api_key` arguments (mapped from Terraform
variables) as a fallback. OAuth2 is supported via `NETSKOPE_OAUTH2_CLIENT_ID`
and `NETSKOPE_OAUTH2_CLIENT_SECRET`.

**Authentication**: `NETSKOPE_API_KEY` is passed directly as the
`Netskope-Api-Token` header on every API call. Any test code or script
that talks directly to the Netskope REST API must use the same env var
and the same header name.

## Enrollment token TTL

`netskope_aig_appliance_enrollment_token` is a create-only resource. The
token it generates expires 24 hours after `terraform apply`. If the instance
has not enrolled in time, `terraform apply` again — it will generate and
store a fresh token. Do not try to import or refresh this resource.

## Common tasks users may ask for

- **"How do I verify the AIG enrolled?"** — See README verification section.
  The Netskope API endpoint is `GET /api/v2/aig/appliances`; status `connected`
  means enrolled and healthy.

- **"I need to re-enroll / the token expired"** — Run `terraform apply` from
  the same directory. The token resource will be replaced, updating the secret.

- **"I want to add DLP or AI Guardrails at bootstrap"** — Add the relevant
  JSON block to the `secret_string` in `aws_secretsmanager_secret_version`.
  See the bootstrap document at `docs/Automated_Bootstrap_Using_AWS_Secrets_Manager.pdf`
  for the exact schema.

- **"I want to use a different AWS region"** — Change `aws_region` and
  `availability_zone` in tfvars. No code changes needed.

- **"The appliance name is too long"** — Netskope enforces a 15-character
  limit. The `appliance_name` variable has a `validation` block that enforces
  this at plan time.

## Required IAM permissions for deployment

These are the AWS permissions the human operator running `terraform apply` needs.
This is separate from the instance profile the AIG EC2 instance uses at runtime
(that role only needs `secretsmanager:GetSecretValue` on the bootstrap secret).

### Scoping approach

| Service | Scope mechanism | Rationale |
|---------|----------------|-----------|
| Secrets Manager | ARN prefix `aig/*` | Matches `var.secret_name` path (default `aig/prod/bootstrap`) |
| IAM roles / profiles | ARN prefix `aig-*` | Matches `var.appliance_name` naming convention |
| IAM PassRole | ARN prefix + service condition | Ensures the role can only be passed to EC2, not other services |
| EC2 Describe | `*` required | AWS does not support resource-level permissions on any Describe operation |
| EC2 Create | `aws:RequestTag/Name: "aig-*"` | Terraform applies the `Name` tag at creation time via TagSpecifications |
| EC2 Modify/Delete | `aws:ResourceTag/Name: "aig-*"` | Resource exists; restrict to already-tagged AIG resources |
| EC2 RunInstances | Split by resource type | Instance/volume/NIC tagged at request; subnet/SG tagged by resource; AMI has no customer tag |

If a customer changes `var.appliance_name` to something other than `aig-*`
(e.g. `prod-aig`), update the IAM prefix conditions to match. The
`var.secret_name` prefix controls the Secrets Manager scope.

### Policy

Replace `${region}` and `${account_id}` before use.
Comments below are for documentation — remove them from the JSON you submit to AWS.

```json
{
  "Version": "2012-10-17",
  "Statement": [

    {
      "Sid": "SecretsManagerAIG",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:CreateSecret",
        "secretsmanager:DeleteSecret",
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetSecretValue",
        "secretsmanager:PutSecretValue",
        "secretsmanager:TagResource"
      ],
      "Resource": "arn:aws:secretsmanager:${region}:${account_id}:secret:aig/*"
    },

    {
      "Sid": "IAMRolesAndProfiles",
      "Effect": "Allow",
      "Action": [
        "iam:AddRoleToInstanceProfile",
        "iam:CreateInstanceProfile",
        "iam:CreateRole",
        "iam:DeleteInstanceProfile",
        "iam:DeleteRole",
        "iam:DeleteRolePolicy",
        "iam:GetInstanceProfile",
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies",
        "iam:PutRolePolicy",
        "iam:RemoveRoleFromInstanceProfile"
      ],
      "Resource": [
        "arn:aws:iam::${account_id}:role/aig-*",
        "arn:aws:iam::${account_id}:instance-profile/aig-*"
      ]
    },

    {
      "Sid": "IAMPassRoleToEC2",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::${account_id}:role/aig-*",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ec2.amazonaws.com"
        }
      }
    },

    {
      "Sid": "EC2Describe",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeAccountAttributes",
        "ec2:DescribeAddresses",
        "ec2:DescribeAddressesAttribute",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceAttribute",
        "ec2:DescribeInstanceCreditSpecifications",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeInternetGateways",
        "ec2:DescribeNatGateways",
        "ec2:DescribeNetworkInterfaceAttribute",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeRouteTables",
        "ec2:DescribeSecurityGroupRules",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets",
        "ec2:DescribeTags",
        "ec2:DescribeVolumes",
        "ec2:DescribeVpcAttribute",
        "ec2:DescribeVpcs"
      ],
      "Resource": "*"
    },

    {
      "Sid": "EC2CreateTagged",
      "Effect": "Allow",
      "Action": [
        "ec2:AllocateAddress",
        "ec2:CreateInternetGateway",
        "ec2:CreateNatGateway",
        "ec2:CreateRouteTable",
        "ec2:CreateSecurityGroup",
        "ec2:CreateSubnet",
        "ec2:CreateVpc"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:RequestTag/Name": "aig-*"
        }
      }
    },

    {
      "Sid": "EC2RunInstancesNewResources",
      "Effect": "Allow",
      "Action": "ec2:RunInstances",
      "Resource": [
        "arn:aws:ec2:${region}:${account_id}:instance/*",
        "arn:aws:ec2:${region}:${account_id}:network-interface/*",
        "arn:aws:ec2:${region}:${account_id}:volume/*"
      ],
      "Condition": {
        "StringLike": {
          "aws:RequestTag/Name": "aig-*"
        }
      }
    },

    {
      "Sid": "EC2RunInstancesFromTaggedResources",
      "Effect": "Allow",
      "Action": "ec2:RunInstances",
      "Resource": [
        "arn:aws:ec2:${region}:${account_id}:security-group/*",
        "arn:aws:ec2:${region}:${account_id}:subnet/*"
      ],
      "Condition": {
        "StringLike": {
          "aws:ResourceTag/Name": "aig-*"
        }
      }
    },

    {
      "Sid": "EC2RunInstancesFromAMI",
      "Effect": "Allow",
      "Action": "ec2:RunInstances",
      "Resource": "arn:aws:ec2:${region}::image/ami-*"
    },

    {
      "Sid": "EC2ModifyDeleteTagged",
      "Effect": "Allow",
      "Action": [
        "ec2:AssociateAddress",
        "ec2:AssociateRouteTable",
        "ec2:AttachInternetGateway",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:CreateRoute",
        "ec2:DeleteInternetGateway",
        "ec2:DeleteNatGateway",
        "ec2:DeleteRoute",
        "ec2:DeleteRouteTable",
        "ec2:DeleteSecurityGroup",
        "ec2:DeleteSubnet",
        "ec2:DeleteVpc",
        "ec2:DetachInternetGateway",
        "ec2:DisassociateAddress",
        "ec2:DisassociateRouteTable",
        "ec2:ModifySubnetAttribute",
        "ec2:ModifyVpcAttribute",
        "ec2:ReleaseAddress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:StopInstances",
        "ec2:TerminateInstances"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:ResourceTag/Name": "aig-*"
        }
      }
    },

    {
      "Sid": "EC2CreateTagsAIG",
      "Effect": "Allow",
      "Action": "ec2:CreateTags",
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:RequestTag/Name": "aig-*"
        }
      }
    },

    {
      "Sid": "EC2DeleteTagsAIG",
      "Effect": "Allow",
      "Action": "ec2:DeleteTags",
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:ResourceTag/Name": "aig-*"
        }
      }
    }

  ]
}
```

### Notes on specific statements

**`EC2Describe` — why `*` is unavoidable**
AWS explicitly does not support resource-level permissions on Describe calls.
Every Terraform plan reads current state using these calls regardless of which
resources will be modified. This is an AWS platform limitation, not a scoping
choice.

**`EC2RunInstances` — why it is split into three statements**
`RunInstances` involves multiple resource types in a single API call. The new
instance, its root volume, and its network interface are resources being
*created* so `aws:RequestTag/Name` applies. The subnet and security group are
*pre-existing* resources selected for the launch, so `aws:ResourceTag/Name`
applies. The AMI is a vendor-owned resource in the AWS account — it carries no
customer-applied `Name` tag, so tag conditions cannot be applied and region
scoping in the ARN is the best available constraint.

**`EC2DeleteTagsAIG` — needed for tag lifecycle, not just destroy**
`ec2:DeleteTags` is called by Terraform when a tag is *removed* from a resource
configuration during `terraform apply` (not only on destroy). Without it, any
tag removal would fail. Scoped by `aws:ResourceTag/Name: "aig-*"` so only
already-tagged AIG resources can be de-tagged via this policy.

**`EC2ModifyDeleteTagged` — covers all `terraform destroy` delete operations**
This statement handles all EC2 resource deletion during `terraform destroy`.
The correct AWS action to delete an EC2 instance is `ec2:TerminateInstances`
(there is no `ec2:DeleteInstance`). Full list covered:

| Action | Resource destroyed |
|--------|--------------------|
| `ec2:TerminateInstances` | EC2 instance (the AIG appliance) |
| `ec2:DeleteSecurityGroup` | AIG security group |
| `ec2:DeleteNatGateway` | NAT Gateway (`new-vpc-private` only) |
| `ec2:ReleaseAddress` | Elastic IP (AIG EIP or NAT EIP) |
| `ec2:DisassociateAddress` | EIP association (`new-vpc-public` only) |
| `ec2:DetachInternetGateway` + `DeleteInternetGateway` | Internet Gateway |
| `ec2:DisassociateRouteTable` + `DeleteRouteTable` + `DeleteRoute` | Route tables |
| `ec2:DeleteSubnet` | Public and private subnets |
| `ec2:DeleteVpc` | VPC |

Note: `ec2:StopInstances` is included for operational use but Terraform calls
`TerminateInstances` directly during destroy — it does not stop first.

All operations are gated on `aws:ResourceTag/Name: "aig-*"`.

**Important**: if a resource loses its `Name: aig-*` tag through manual
intervention, `terraform destroy` will be **denied** for that resource. This is
intentional — it prevents accidental deletion of unrelated resources — but it
means you cannot destroy a de-tagged resource with this policy alone. Add the
specific resource ARN to a one-off statement if recovery is needed.

**`EC2CreateTagsAIG` — `aws:RequestTag` not `aws:ResourceTag`**
This permission covers two scenarios: tagging sub-resources (volumes, network
interfaces) inline during `RunInstances`, and any subsequent `CreateTags` call
Terraform makes. In both cases the tag being *applied* is `aig-*`, which
`aws:RequestTag/Name` evaluates correctly. Using `aws:ResourceTag/Name` here
would block tagging of new resources that do not yet carry a tag.

**`existing-vpc` deployments**
The VPC and subnet already exist and may be owned by another team. The operator
running Terraform only needs the Describe permissions for those resources (already
included in `EC2Describe`). No Create/Delete permissions for VPC or subnet are
required when using the `existing-vpc` template.

## What not to change without careful thought

- The `depends_on` blocks on `aws_instance` — they ensure the secret and
  network route are ready before the instance boots.
- The `netskope_aig_appliance` → `netskope_aig_appliance_enrollment_token`
  → `aws_secretsmanager_secret_version` → `aws_instance` dependency chain.
  Breaking this order will cause enrollment to fail silently.
