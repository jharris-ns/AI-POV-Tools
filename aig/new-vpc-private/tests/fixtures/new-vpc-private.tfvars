# Test fixture values for new-vpc-private
# Used by terraform test (Layer 1 — plan-only with mock providers) and
# integration tests (Layer 2 — real AWS deployment).
#
# For integration tests the real AMI default is used automatically.
# Override aig_ami_id on the CLI for a different region:
#   make test-integration AWS_REGION=us-west-1 AMI_ID=ami-xxxxx

appliance_name      = "aig-test"
aws_region          = "us-west-1"
availability_zone   = "us-west-1b"
vpc_cidr            = "10.0.0.0/16"
public_subnet_cidr  = "10.0.0.0/24"
private_subnet_cidr = "10.0.1.0/24"
aig_private_ip      = "10.0.1.10"
allowed_cidr_blocks = ["10.0.0.0/16"]
instance_type       = "c6a.4xlarge"
key_name            = "justin-us-west-1"
secret_name         = "aig/test/bootstrap"