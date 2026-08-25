terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    netskope = {
      source  = "netskopeoss/netskope"
      version = "~> 0.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "netskope" {
  # Credentials via environment variables (recommended):
  #   NETSKOPE_SERVER_URL = "https://mycompany.goskope.com/api/v2"
  #   NETSKOPE_API_KEY    = "your-rest-api-v2-token"
  server_url = var.netskope_server_url
  api_key    = var.netskope_api_key
}

# ── Netskope: register appliance + generate enrollment token ──────────────────
#
# appliance_host is provided as a variable — set it to the IP or hostname the
# AIG instance will be reachable at within your existing network.

resource "netskope_aig_appliance" "this" {
  name = var.appliance_name
  host = var.appliance_host

  ports = {
    https = { enable = true, port = 443 }
    http  = { enable = false, port = 80 }
  }
}

resource "netskope_aig_appliance_enrollment_token" "this" {
  appliance_id = netskope_aig_appliance.this.id
}

# ── Secrets Manager: bootstrap secret ────────────────────────────────────────

resource "aws_secretsmanager_secret" "aig_bootstrap" {
  name                    = var.secret_name
  description             = "Netskope AIG automated bootstrap — enrollment token"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "aig_bootstrap" {
  secret_id = aws_secretsmanager_secret.aig_bootstrap.id
  secret_string = jsonencode({
    bootstrap        = true
    enrollment_token = netskope_aig_appliance_enrollment_token.this.enrollment_token
  })
}

# ── IAM: instance role scoped to this one secret ─────────────────────────────

resource "aws_iam_role" "aig" {
  name = "${var.appliance_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "aig_read_secret" {
  name = "${var.appliance_name}-read-bootstrap-secret"
  role = aws_iam_role.aig.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadAIGBootstrapSecret"
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.aig_bootstrap.arn
    }]
  })
}

resource "aws_iam_instance_profile" "aig" {
  name = "${var.appliance_name}-instance-profile"
  role = aws_iam_role.aig.name
}

# ── Security Group ────────────────────────────────────────────────────────────

resource "aws_security_group" "aig" {
  name        = "${var.appliance_name}-sg"
  description = "Netskope AI Gateway"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS proxy"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.appliance_name}-sg" }
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "aig" {
  ami                    = var.aig_ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  iam_instance_profile   = aws_iam_instance_profile.aig.name
  vpc_security_group_ids = [aws_security_group.aig.id]
  key_name               = var.key_name

  user_data = jsonencode({
    bootstrap_secret = aws_secretsmanager_secret.aig_bootstrap.name
  })

  tags = { Name = var.appliance_name }

  depends_on = [aws_secretsmanager_secret_version.aig_bootstrap]
}
