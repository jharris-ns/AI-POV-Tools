terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ── IAM Policy ────────────────────────────────────────────────────────────────
#
# Minimum permissions to run terraform plan/apply/destroy against any of the
# three AIG deployment templates (existing-vpc, new-vpc-public, new-vpc-private).
#
# Scoping rules:
#   Secrets Manager  — scoped to var.secret_prefix   (default "aig/")
#   IAM roles/profiles — scoped to var.resource_prefix (default "aig-")
#   EC2 mutating ops — scoped by Name tag matching var.resource_prefix
#   EC2 Describe ops — Resource: * (AWS does not support resource-level permissions)

resource "aws_iam_policy" "aig_deployment" {
  name        = "${var.role_name}-policy"
  description = "Minimum permissions to deploy the Netskope AI Gateway via Terraform"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [

      # ── Secrets Manager ────────────────────────────────────────────────────
      {
        Sid    = "SecretsManagerAIG"
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret",
          "secretsmanager:DeleteSecret",
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:TagResource"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${local.account_id}:secret:${var.secret_prefix}*"
      },

      # ── IAM Roles and Instance Profiles ────────────────────────────────────
      {
        Sid    = "IAMRolesAndProfiles"
        Effect = "Allow"
        Action = [
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
        ]
        Resource = [
          "arn:aws:iam::${local.account_id}:role/${var.resource_prefix}*",
          "arn:aws:iam::${local.account_id}:instance-profile/${var.resource_prefix}*"
        ]
      },

      # ── IAM PassRole ────────────────────────────────────────────────────────
      {
        Sid      = "IAMPassRoleToEC2"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "arn:aws:iam::${local.account_id}:role/${var.resource_prefix}*"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      },

      # ── EC2 Read ────────────────────────────────────────────────────────────
      # AWS does not support resource-level permissions on Describe operations.
      {
        Sid    = "EC2Describe"
        Effect = "Allow"
        Action = [
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
        ]
        Resource = "*"
      },

      # ── EC2 Create ──────────────────────────────────────────────────────────
      # Terraform applies the Name tag at creation time via TagSpecifications,
      # so aws:RequestTag/Name is evaluated at the moment of the API call.
      {
        Sid    = "EC2CreateTagged"
        Effect = "Allow"
        Action = [
          "ec2:AllocateAddress",
          "ec2:CreateInternetGateway",
          "ec2:CreateNatGateway",
          "ec2:CreateRouteTable",
          "ec2:CreateSecurityGroup",
          "ec2:CreateSubnet",
          "ec2:CreateVpc"
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:RequestTag/Name" = "${var.resource_prefix}*"
          }
        }
      },

      # ── EC2 RunInstances ─────────────────────────────────────────────────────
      # Split across three statements because each resource type in the API call
      # requires a different condition:
      #   - Instance, volume, NIC: being created → aws:RequestTag
      #   - Subnet, SG: pre-existing resources selected for launch → aws:ResourceTag
      #   - AMI: vendor-owned, no customer Name tag → region-scoped ARN only
      {
        Sid    = "EC2RunInstancesNewResources"
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = [
          "arn:aws:ec2:${var.aws_region}:${local.account_id}:instance/*",
          "arn:aws:ec2:${var.aws_region}:${local.account_id}:network-interface/*",
          "arn:aws:ec2:${var.aws_region}:${local.account_id}:volume/*"
        ]
        Condition = {
          StringLike = {
            "aws:RequestTag/Name" = "${var.resource_prefix}*"
          }
        }
      },
      {
        Sid    = "EC2RunInstancesFromTaggedResources"
        Effect = "Allow"
        Action = "ec2:RunInstances"
        Resource = [
          "arn:aws:ec2:${var.aws_region}:${local.account_id}:security-group/*",
          "arn:aws:ec2:${var.aws_region}:${local.account_id}:subnet/*"
        ]
        Condition = {
          StringLike = {
            "aws:ResourceTag/Name" = "${var.resource_prefix}*"
          }
        }
      },
      {
        Sid      = "EC2RunInstancesFromAMI"
        Effect   = "Allow"
        Action   = "ec2:RunInstances"
        Resource = "arn:aws:ec2:${var.aws_region}::image/ami-*"
      },

      # ── EC2 Modify / Delete ──────────────────────────────────────────────────
      # Covers all terraform destroy operations. Gated on the resource already
      # carrying the Name tag. If a resource loses its tag, it cannot be deleted
      # via this policy — see CLAUDE.md for recovery guidance.
      {
        Sid    = "EC2ModifyDeleteTagged"
        Effect = "Allow"
        Action = [
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
        ]
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:ResourceTag/Name" = "${var.resource_prefix}*"
          }
        }
      },

      # ── EC2 Tag Management ───────────────────────────────────────────────────
      {
        Sid      = "EC2CreateTagsAIG"
        Effect   = "Allow"
        Action   = "ec2:CreateTags"
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:RequestTag/Name" = "${var.resource_prefix}*"
          }
        }
      },
      {
        Sid      = "EC2DeleteTagsAIG"
        Effect   = "Allow"
        Action   = "ec2:DeleteTags"
        Resource = "*"
        Condition = {
          StringLike = {
            "aws:ResourceTag/Name" = "${var.resource_prefix}*"
          }
        }
      }

    ]
  })
}

# ── IAM Role ──────────────────────────────────────────────────────────────────

resource "aws_iam_role" "aig_deployment" {
  name        = var.role_name
  description = "Deployment role for Netskope AI Gateway Terraform templates"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.trusted_principal_arns }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "aig_deployment" {
  role       = aws_iam_role.aig_deployment.name
  policy_arn = aws_iam_policy.aig_deployment.arn
}
