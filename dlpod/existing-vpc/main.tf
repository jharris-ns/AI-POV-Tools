terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

data "aws_region" "current" {}

# ── TLS: DLPoD CA + server certificate ───────────────────────────────────────
#
# DLPoD rejects CA:TRUE certs in dlpaas.server-cert. A two-tier hierarchy is
# required:
#
#   tls_self_signed_cert.dlpod_ca  — self-signed CA (CA:TRUE, cert_signing)
#   tls_locally_signed_cert.dlpod  — server cert signed by CA (CA:FALSE, server_auth)
#
# Bootstrap mapping:
#   dlpaas.server-cert                  → leaf cert (CA:FALSE)
#   dlpaas.server-key                   → server private key (PKCS#8)
#   dlpaas.server-intermediate-ca-chain → CA cert
#
# The CA cert PEM is exported as the ca_cert_pem output. Pass it to the AIG
# template as dlp_ca_cert_pem — the AIG uses it to verify DLPoD's TLS chain.
#
# Private key material lives in Terraform state. Use S3 remote state with
# SSE-KMS encryption to protect it at rest.

resource "tls_private_key" "dlpod_ca" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "dlpod_ca" {
  private_key_pem = tls_private_key.dlpod_ca.private_key_pem

  subject {
    common_name  = "Netskope POV DLPoD CA"
    organization = "Netskope POV"
  }

  validity_period_hours = 8760
  is_ca_certificate     = true

  allowed_uses = [
    "cert_signing",
    "crl_signing",
  ]
}

resource "tls_private_key" "dlpod" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "dlpod" {
  private_key_pem = tls_private_key.dlpod.private_key_pem

  subject {
    common_name  = var.dlpod_hostname
    organization = "Netskope POV"
  }

  dns_names    = [var.dlpod_hostname]
  ip_addresses = [var.dlpod_private_ip]
}

resource "tls_locally_signed_cert" "dlpod" {
  cert_request_pem   = tls_cert_request.dlpod.cert_request_pem
  ca_private_key_pem = tls_private_key.dlpod_ca.private_key_pem
  ca_cert_pem        = tls_self_signed_cert.dlpod_ca.cert_pem

  validity_period_hours = 8760
  is_ca_certificate     = false

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  name_prefix = "${var.project}-${var.environment}"

  # Extract the parent DNS zone from dlpod_hostname
  # e.g. "dlp.aigw.internal" → "aigw.internal"
  dlpod_dns_zone = join(".", slice(split(".", var.dlpod_hostname), 1, length(split(".", var.dlpod_hostname))))

  _dlpod_system = merge(
    { licensekey = var.dlpod_licensekey },
    { hostname = var.dlpod_hostname },
    var.dlpod_ssh_public_key != "" ? {
      ssh-public-keys = [{ key = var.dlpod_ssh_public_key, user = "nsadmin" }]
    } : {}
  )

  dlpod_bootstrap = {
    persona = "dlp-on-demand"
    dns = {
      # VPC DNS resolver is always the VPC base address + 2
      primary = cidrhost(var.vpc_cidr, 2)
    }
    interface = {
      v4 = { dhcp = { enable = true } }
    }
    system = local._dlpod_system
    dlpaas = {
      "server-cert"                  = tls_locally_signed_cert.dlpod.cert_pem
      "server-key"                   = tls_private_key.dlpod.private_key_pem_pkcs8
      "server-intermediate-ca-chain" = tls_self_signed_cert.dlpod_ca.cert_pem
    }
  }
}

# ── IAM ───────────────────────────────────────────────────────────────────────
#
# DLPoD reads its bootstrap config from raw EC2 user-data — no AWS API calls
# are made at boot. The instance profile exists to provide an EC2 identity for
# operational tooling (e.g. if you later attach AmazonSSMManagedInstanceCore).

resource "aws_iam_role" "dlpod" {
  name = "${local.name_prefix}-dlpod-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_instance_profile" "dlpod" {
  name = "${local.name_prefix}-dlpod-instance-profile"
  role = aws_iam_role.dlpod.name
}

# ── Security Group ────────────────────────────────────────────────────────────
#
# Port 443 is scoped to allowed_inspection_cidr — set this to the subnet or
# CIDR where your AIG will live. After deploying the AIG you can optionally
# replace the CIDR rule with a security group reference for tighter scoping.

resource "aws_security_group" "dlpod" {
  name        = "${local.name_prefix}-dlpod-sg"
  description = "Netskope DLP On-Demand appliance"
  vpc_id      = var.vpc_id

  ingress {
    description = "DLP inspection from AIG (port 443 TLS)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_inspection_cidr]
  }

  ingress {
    description = "SSH from allowed CIDR (use SSM where possible)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    description = "All outbound — Netskope cloud, licensing, OS updates"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-dlpod-sg" }
}

# ── Route 53 — private hosted zone ───────────────────────────────────────────
#
# The AIG connects to DLPoD via hostname (https://dlp.aigw.internal) rather
# than a bare IP. Go's TLS stack verifies the hostname against the cert's DNS
# SANs — a bare-IP URL causes it to verify against an empty string, which
# always fails even if the cert has a valid IP SAN.
#
# This private hosted zone resolves dlpod_hostname → dlpod_private_ip within
# the VPC. The AIG must be in the same VPC (or a VPC associated with this zone)
# for the lookup to succeed.

resource "aws_route53_zone" "dlpod" {
  name = local.dlpod_dns_zone

  vpc {
    vpc_id = var.vpc_id
  }

  tags = { Name = "${local.name_prefix}-${local.dlpod_dns_zone}" }
}

resource "aws_route53_record" "dlpod" {
  zone_id = aws_route53_zone.dlpod.zone_id
  name    = var.dlpod_hostname
  type    = "A"
  ttl     = 60
  records = [var.dlpod_private_ip]
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────
#
# Private IP is pinned so the AIG bootstrap secret can embed dlp.host and the
# TLS cert SAN are consistent before the instance exists. The IP must be a free
# address within the subnet CIDR.
#
# IMDSv2 is enforced to block SSRF reads of user-data (which contains the
# license key and TLS private key) from redirect-based attack paths and
# containerised workloads.
#
# 9000 IOPS on the root volume speeds up nsbootstrap initialisation
# significantly. Reduce to 3000 IOPS after bootstrap completes if cost matters.

resource "aws_instance" "dlpod" {
  ami                    = var.dlpod_ami_id
  instance_type          = var.dlpod_instance_type
  subnet_id              = var.subnet_id
  private_ip             = var.dlpod_private_ip
  iam_instance_profile   = aws_iam_instance_profile.dlpod.name
  vpc_security_group_ids = [aws_security_group.dlpod.id]
  key_name               = var.key_pair_name != "" ? var.key_pair_name : null

  # Raw JSON bootstrap.json — read by nsbootstrap.service at first boot.
  user_data = jsonencode(local.dlpod_bootstrap)

  root_block_device {
    volume_type           = "gp3"
    iops                  = 9000
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = { Name = "${local.name_prefix}-dlpod" }
}
