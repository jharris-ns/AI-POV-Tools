# Test fixture values for existing-vpc.
# vpc_id, subnet_id, and appliance_host are injected at runtime via -var flags
# (derived from the test-network fixture outputs).

appliance_name      = "aig-test"
aws_region          = "us-west-1"
allowed_cidr_blocks = ["10.0.0.0/16"]
instance_type       = "c6a.4xlarge"
key_name            = "justin-us-west-1"
secret_name         = "aig/test/bootstrap"
