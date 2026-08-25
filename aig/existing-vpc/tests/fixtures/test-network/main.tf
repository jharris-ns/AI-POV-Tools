# Minimal network fixture for existing-vpc integration tests.
# Creates a VPC with a public subnet (IGW + route table) so the AIG
# instance can reach Netskope cloud and Secrets Manager for enrollment.

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
  region = "us-west-1"
}

resource "aws_vpc" "test" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "aig-test-vpc" }
}

resource "aws_subnet" "test" {
  vpc_id                  = aws_vpc.test.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = "us-west-1b"
  map_public_ip_on_launch = true
  tags = { Name = "aig-test-subnet" }
}

resource "aws_internet_gateway" "test" {
  vpc_id = aws_vpc.test.id
  tags   = { Name = "aig-test-igw" }
}

resource "aws_route_table" "test" {
  vpc_id = aws_vpc.test.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.test.id
  }

  tags = { Name = "aig-test-rt" }
}

resource "aws_route_table_association" "test" {
  subnet_id      = aws_subnet.test.id
  route_table_id = aws_route_table.test.id
}

output "vpc_id" {
  value = aws_vpc.test.id
}

output "subnet_id" {
  value = aws_subnet.test.id
}
