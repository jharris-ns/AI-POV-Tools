# Layer 1 — Terraform native tests for new-vpc-private
#
# These tests use mock_provider so no AWS or Netskope credentials are required.
# Mock providers assign predictable values to computed attributes (like resource
# IDs) during apply. Four blocks use `command = plan` to test values that are
# known at plan time (user-specified arguments). The remaining blocks default to
# `command = apply` so computed references (IDs) are resolved before assertions.
#
# Run from the repo root:
#   cd terraform/aig/tests && make test-static
# Or directly:
#   cd terraform/aig/new-vpc-private && terraform test

mock_provider "aws" {}
mock_provider "netskope" {}

variables {
  # All other variables use defaults defined in variables.tf.
  appliance_name = "aig-test"
  secret_name    = "aig/test/bootstrap"
}

# ── Plan-time checks (user-specified arguments — known before apply) ──────────

run "vpc_cidr" {
  command = plan

  assert {
    condition     = aws_vpc.this.cidr_block == "10.0.0.0/16"
    error_message = "VPC CIDR block must be 10.0.0.0/16 (default)"
  }
}

run "vpc_dns" {
  command = plan

  assert {
    condition     = aws_vpc.this.enable_dns_support == true
    error_message = "VPC must have DNS support enabled (required for Secrets Manager and Netskope endpoints)"
  }

  assert {
    condition     = aws_vpc.this.enable_dns_hostnames == true
    error_message = "VPC must have DNS hostnames enabled"
  }
}

run "public_subnet_cidr" {
  command = plan

  assert {
    condition     = aws_subnet.public.cidr_block == "10.0.0.0/24"
    error_message = "Public subnet CIDR must be 10.0.0.0/24 (default)"
  }
}

run "private_subnet_cidr" {
  command = plan

  assert {
    condition     = aws_subnet.private.cidr_block == "10.0.1.0/24"
    error_message = "Private subnet CIDR must be 10.0.1.0/24 (default)"
  }
}

# ── Apply-time checks (cross-resource references — IDs are computed) ──────────
#
# mock_provider assigns mock IDs during apply. The first apply block below
# creates all resources. Subsequent blocks see no changes but can assert on
# the mocked state values.

run "nat_in_public_subnet" {
  # command defaults to apply — resolves aws_subnet.public.id via mock_provider
  assert {
    condition     = aws_nat_gateway.this.subnet_id == aws_subnet.public.id
    error_message = "NAT Gateway must be placed in the public subnet"
  }
}

run "public_route_via_igw" {
  assert {
    condition = length([
      for r in aws_route_table.public.route :
      r if r.cidr_block == "0.0.0.0/0" && r.gateway_id != ""
    ]) > 0
    error_message = "Public route table must route 0.0.0.0/0 via an Internet Gateway"
  }
}

run "private_route_via_nat" {
  assert {
    condition = length([
      for r in aws_route_table.private.route :
      r if r.cidr_block == "0.0.0.0/0" && r.nat_gateway_id != ""
    ]) > 0
    error_message = "Private route table must route 0.0.0.0/0 via NAT Gateway"
  }
}

run "ec2_in_private_subnet" {
  assert {
    condition     = aws_instance.aig.subnet_id == aws_subnet.private.id
    error_message = "AIG EC2 instance must be placed in the private subnet"
  }
}

run "ec2_fixed_ip" {
  assert {
    condition     = aws_instance.aig.private_ip == "10.0.1.10"
    error_message = "AIG EC2 instance must use the fixed private IP 10.0.1.10 (default aig_private_ip)"
  }
}

run "secret_recovery_window" {
  assert {
    condition     = aws_secretsmanager_secret.aig_bootstrap.recovery_window_in_days == 0
    error_message = "Bootstrap secret must have recovery_window_in_days=0 to allow destroy/apply cycles without a 7-day wait"
  }
}

run "user_data_bootstrap_secret" {
  assert {
    condition     = strcontains(aws_instance.aig.user_data, var.secret_name)
    error_message = "EC2 user_data must reference the bootstrap secret name so the AIG knows where to fetch its enrollment token"
  }
}

run "security_group_rules" {
  assert {
    condition     = length(aws_security_group.aig.ingress) == 1
    error_message = "AIG security group must have exactly 1 ingress rule (TCP 443)"
  }

  assert {
    condition     = length(aws_security_group.aig.egress) == 3
    error_message = "AIG security group must have exactly 3 egress rules (TCP 443, UDP 53, TCP 53)"
  }
}
