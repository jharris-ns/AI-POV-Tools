variable "aws_region" {
  description = "AWS region where AIG will be deployed — used to scope EC2 and Secrets Manager ARNs"
  type        = string
  default     = "us-east-1"
}

variable "role_name" {
  description = "Name for the IAM deployment role"
  type        = string
  default     = "aig-deployment-role"
}

variable "trusted_principal_arns" {
  description = "IAM principal ARNs permitted to assume this role (IAM users, roles, or the account root)"
  type        = list(string)
}

# ── Prefix coupling ───────────────────────────────────────────────────────────
# These must match the prefixes used in the deployment template you will run.
# Default values align with the defaults in existing-vpc/, new-vpc-public/,
# and new-vpc-private/:
#   var.appliance_name defaults to "aig-pov"  → resource_prefix = "aig-"
#   var.secret_name    defaults to "aig/prod/bootstrap" → secret_prefix = "aig/"

variable "resource_prefix" {
  description = "Prefix for EC2 and IAM resource Names — must match the appliance_name prefix in the deployment template"
  type        = string
  default     = "aig-"
}

variable "secret_prefix" {
  description = "Path prefix for Secrets Manager secret names — must match the secret_name prefix in the deployment template"
  type        = string
  default     = "aig/"
}
