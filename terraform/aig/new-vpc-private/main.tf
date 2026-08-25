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

# ── VPC ───────────────────────────────────────────────────────────────────────
#
# DNS support is required so the AIG can resolve Secrets Manager, Netskope
# cloud endpoints, and AI provider hostnames at boot.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.appliance_name}-vpc" }
}

# ── Subnets ───────────────────────────────────────────────────────────────────
#
# Public subnet: NAT Gateway only — no AIG instances here.
# Private subnet: AIG instance — outbound via NAT, no inbound from internet.

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_subnet_cidr
  availability_zone = var.availability_zone

  tags = { Name = "${var.appliance_name}-public" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.availability_zone

  tags = { Name = "${var.appliance_name}-private" }
}

# ── Internet Gateway ──────────────────────────────────────────────────────────

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.appliance_name}-igw" }
}

# ── NAT Gateway ───────────────────────────────────────────────────────────────
#
# The AIG needs outbound internet to reach Netskope cloud and AI providers.
# NAT Gateway in the public subnet provides this without exposing the AIG directly.

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${var.appliance_name}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = { Name = "${var.appliance_name}-nat" }

  depends_on = [aws_internet_gateway.this]
}

# ── Route Tables ──────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.appliance_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = { Name = "${var.appliance_name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ── Netskope: register appliance + generate enrollment token ──────────────────
#
# host uses a fixed private IP (var.aig_private_ip) so Netskope registration
# can happen before the EC2 instance exists. The same IP is pinned on the
# instance below, keeping them consistent.

resource "netskope_aig_appliance" "this" {
  name = var.appliance_name
  host = var.aig_private_ip

  ports = {
    https = { enable = true, port = 443 }
    http  = { enable = false, port = 80 }
  }
}

resource "netskope_aig_appliance_enrollment_token" "this" {
  appliance_id = netskope_aig_appliance.this.id
}

# ── Secrets Manager: bootstrap secret ────────────────────────────────────────
#
# At first boot the AIG reads user_data, retrieves this secret via the instance
# profile, and completes enrollment automatically — no SSH or CLI needed.

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
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS proxy"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    description = "HTTPS outbound"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS UDP"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS TCP"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.appliance_name}-sg" }
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────

resource "aws_instance" "aig" {
  ami                    = var.aig_ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  private_ip             = var.aig_private_ip
  iam_instance_profile   = aws_iam_instance_profile.aig.name
  vpc_security_group_ids = [aws_security_group.aig.id]

  user_data = jsonencode({
    bootstrap_secret = aws_secretsmanager_secret.aig_bootstrap.name
  })

  tags = { Name = var.appliance_name }

  depends_on = [
    aws_secretsmanager_secret_version.aig_bootstrap,
    aws_nat_gateway.this,
  ]
}
