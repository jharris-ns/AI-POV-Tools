# IAM permissions for deploying the combined AI Services stack

These are the AWS permissions needed by the **person or CI principal running `terraform apply`** in `ai-services-all/new-vpc-public-v5/`. They are broader than the AIG-only policy in [`aig/docs/iam-permissions.md`](../../../aig/docs/iam-permissions.md) because this template also creates VPC endpoints, SSM parameters, CloudWatch log groups and a Route 53 zone, and runs `aws` CLI commands from your machine to poll readiness.

Instance roles (what the EC2 instances themselves can do) are created by the template and are not listed here. No S3 permissions are required for the Guardrails image bucket: that access is granted to the Guardrails instance role, not to the Terraform operator.

> **How this list was built.** It is derived from the resources and `local-exec` commands in the `.tf` files, not from a least-privilege test apply. If an apply fails with `AccessDenied`, the error names the missing action: add it here and to your policy. Run `terraform plan` first. A plan exercises most of the read permissions without creating anything.

## What the template creates

| Feature | Always | Only with |
|---------|--------|-----------|
| VPC, subnets, IGW, NAT gateway, route tables, 5 VPC endpoints, 2 Elastic IPs | yes | |
| AIG, Guardrails and DLPoD instances, security groups, IAM roles and profiles | yes | |
| Secrets Manager: `bootstrap` | yes | |
| SSM parameter `/<prefix>/guardrails-ready`, CloudWatch log group, Route 53 private zone | yes | |
| EC2 key pair (imported from the generated or supplied key) | yes | |
| Bastion instance, role, security group and rules, `aig-ready` parameter, `ssh-private-key`, `ca-key` and `ca-cert` secrets | | `enable_bastion` (default `true`) |
| Windows 11 VM, role, security group, Elastic IP | | `enable_win11_vm` |
| LibreChat instance, role, security group, Elastic IP, `librechat-tls` secret | | `enable_librechat` |

The optional features need **no actions beyond the lists below**. They use the same EC2, IAM and Secrets Manager actions as the core stack. The only new resource name is the LibreChat secret, `aig/<aws_object_unique_prefix>/librechat-tls`, which is covered by the `aig/*` scope.

## EC2

```
ec2:Describe*                                    ← includes DescribeImages (Ubuntu AMI lookup) and DescribeKeyPairs
ec2:AllocateAddress / ReleaseAddress / AssociateAddress / DisassociateAddress
ec2:CreateVpc / DeleteVpc / ModifyVpcAttribute
ec2:CreateSubnet / DeleteSubnet / ModifySubnetAttribute
ec2:CreateInternetGateway / DeleteInternetGateway / AttachInternetGateway / DetachInternetGateway
ec2:CreateNatGateway / DeleteNatGateway
ec2:CreateRouteTable / DeleteRouteTable / AssociateRouteTable / DisassociateRouteTable / CreateRoute / DeleteRoute
ec2:CreateSecurityGroup / DeleteSecurityGroup
ec2:AuthorizeSecurityGroupIngress / AuthorizeSecurityGroupEgress
ec2:RevokeSecurityGroupIngress / RevokeSecurityGroupEgress
ec2:RunInstances / StartInstances / StopInstances / TerminateInstances
ec2:ModifyInstanceAttribute                      ← in-place changes, for example user data on Guardrails
ec2:ImportKeyPair / DeleteKeyPair                ← the new key pair, unless every *_key_pair_name is set
ec2:CreateVpcEndpoint / DeleteVpcEndpoints / ModifyVpcEndpoint
ec2:CreateTags / DeleteTags                      ← default_tags (owner, purpose, terminate_after, …) go on every resource
```

`ec2:RunInstances` is authorized against the instance, volume, network interface, AMI, subnet and security group resources. If you scope it by resource, allow all of those.

## IAM

```
iam:CreateRole / DeleteRole / GetRole / UpdateAssumeRolePolicy
iam:TagRole / UntagRole                          ← default_tags are applied to roles
iam:CreateInstanceProfile / DeleteInstanceProfile / GetInstanceProfile
iam:TagInstanceProfile / UntagInstanceProfile
iam:AddRoleToInstanceProfile / RemoveRoleFromInstanceProfile / ListInstanceProfilesForRole
iam:PutRolePolicy / DeleteRolePolicy / GetRolePolicy / ListRolePolicies
iam:AttachRolePolicy / DetachRolePolicy / ListAttachedRolePolicies
iam:PassRole                                     ← scoped to the template's roles, with iam:PassedToService = ec2.amazonaws.com
```

`AttachRolePolicy` is used to attach the AWS managed policy `AmazonSSMManagedInstanceCore` to the Guardrails, bastion, Windows 11 and LibreChat roles. You can restrict it with `iam:PolicyARN` to that one policy. Role names start with the `aws_object_unique_prefix` value, so scope the IAM actions to `arn:aws:iam::<account>:role/<prefix>-*` and `instance-profile/<prefix>-*`.

## Secrets Manager

```
secretsmanager:CreateSecret / DeleteSecret / DescribeSecret / UpdateSecret
secretsmanager:GetSecretValue / PutSecretValue / GetResourcePolicy
secretsmanager:TagResource / UntagResource
```

Every secret is named `aig/<aws_object_unique_prefix>/…`: `bootstrap`, `ssh-private-key`, `ca-key`, `ca-cert` and, with LibreChat, `librechat-tls`. If `secret_name` is set it must also start with `aig/`. Scope these actions to `arn:aws:secretsmanager:<region>:<account>:secret:aig/*`. The instances' own roles are scoped by Terraform to the individual secrets they read.

## SSM

```
ssm:PutParameter / GetParameter / DeleteParameter   ← guardrails-ready and aig-ready parameters
ssm:DescribeParameters
ssm:AddTagsToResource / RemoveTagsFromResource / ListTagsForResource
ssm:SendCommand / GetCommandInvocation              ← DLPoD readiness gate (wait_for_dlpod_to_deploy_aig)
ssm:DescribeInstanceInformation
```

- The parameters are `/<prefix>/guardrails-ready` and, with the bastion, `/<prefix>/aig-ready`. Scope the parameter actions to `arn:aws:ssm:<region>:<account>:parameter/<prefix>/*`.
- `ssm:SendCommand` is needed only when `wait_for_dlpod_to_deploy_aig = true`. It targets the bastion, or the Guardrails instance when `enable_bastion = false`, using the document `AWS-RunShellScript`. Scope it to `arn:aws:ssm:<region>::document/AWS-RunShellScript` and the instance ARNs.
- Session Manager access for troubleshooting (`ssm:StartSession`, `ssm:TerminateSession`) is for the person debugging, not for `terraform apply`. Add it for whoever will use the `*_ssm_connect_command` outputs.

## CloudWatch Logs

```
logs:CreateLogGroup / DeleteLogGroup / DescribeLogGroups
logs:PutRetentionPolicy / DeleteRetentionPolicy
logs:TagResource / UntagResource / ListTagsForResource
```

## Route 53

```
route53:CreateHostedZone / DeleteHostedZone / GetHostedZone / ListHostedZones
route53:ChangeResourceRecordSets / ListResourceRecordSets / GetChange
route53:ChangeTagsForResource / ListTagsForResource
```

Creating the private zone also reads the VPC (`ec2:DescribeVpcs`, `ec2:DescribeRegions`), which `ec2:Describe*` already covers.

## Commands that run from your machine

Several resources run local commands during `apply`. They use whatever credentials and tools your shell has, **not** the Terraform provider's configuration.

| Command | When | Needs |
|---------|------|-------|
| `openssl` | Creating or destroying the lab root CA (when `ca_existing_signing_key_local_path` is blank) | `openssl` on the `PATH` |
| `aws ssm get-parameter` / `put-parameter` | Guardrails and AIG readiness gates (`wait_for_guardrails_to_deploy_*`, `wait_for_aig_to_complete_template`) | `aws` CLI on the `PATH`; `ssm:GetParameter`, `ssm:PutParameter` |
| `aws ssm send-command` / `get-command-invocation` | DLPoD readiness gate (`wait_for_dlpod_to_deploy_aig`) | `aws` CLI on the `PATH`; `ssm:SendCommand`, `ssm:GetCommandInvocation` |

Select credentials with `export AWS_PROFILE=<profile>` (or any other standard credential source) before running Terraform, so the provider and these commands use the same identity. The provider block in `main.tf` sets no `profile` on purpose: the `aws` CLI commands above would not see it and would fail with "Unable to locate credentials". With every `wait_for_*` variable `false` (the default), the SSM gates poll nothing.

## Remote state (optional — recommended)

```
s3:GetObject / PutObject / DeleteObject / ListBucket   on your tfstate bucket
dynamodb:GetItem / PutItem / DeleteItem                on your lock table (if using DynamoDB locking)
kms:Encrypt / Decrypt / GenerateDataKey                on the state KMS key (if the bucket uses SSE-KMS)
```

State holds TLS private keys in plaintext. See [deployment.md](deployment.md) for the backend configuration.

## Tear down

`terraform destroy` needs the delete and detach counterparts of the actions above. Those are all listed. Destroy also removes the Netskope appliance registration, which uses the Netskope API token, not AWS permissions.
