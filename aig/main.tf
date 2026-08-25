# This directory is not a Terraform root.
# Choose the deployment that matches your environment:
#
#   existing-vpc/     — use an existing VPC and subnet
#   new-vpc-public/   — create a new VPC, AIG in public subnet with Elastic IP
#   new-vpc-private/  — create a new VPC, AIG in private subnet behind NAT Gateway
#
# Example:
#   cd new-vpc-private
#   cp terraform.tfvars.example terraform.tfvars
#   terraform init && terraform apply
