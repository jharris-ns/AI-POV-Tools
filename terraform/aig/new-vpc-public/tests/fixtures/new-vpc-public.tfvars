# Test fixture values for new-vpc-public
# Used by integration tests (Layer 2 — real AWS deployment).

appliance_name      = "aig-test"
aws_region          = "us-west-1"
availability_zone   = "us-west-1b"
vpc_cidr            = "10.0.0.0/16"
public_subnet_cidr  = "10.0.0.0/24"
allowed_cidr_blocks = ["10.0.0.0/16"]
instance_type       = "c6a.4xlarge"
key_name            = "justin-us-west-1"
secret_name         = "aig/test/bootstrap"
