# ── AWS ───────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region where the existing VPC lives"
  type        = string
  default     = "us-west-1"
}

# ── Existing VPC ──────────────────────────────────────────────────────────────

variable "vpc_id" {
  description = "ID of the existing VPC to deploy the AI Gateway into"
  type        = string
}

variable "subnet_id" {
  description = "ID of the existing subnet for the AI Gateway EC2 instance"
  type        = string
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks permitted to reach the AI Gateway on port 443"
  type        = list(string)
}

# ── EC2 ───────────────────────────────────────────────────────────────────────

variable "aig_ami_id" {
  description = "AMI ID for the Netskope AI Gateway appliance. Default is us-east-1; update for other regions."
  type        = string
  default     = "ami-0a66805d7fb085df4"
}

variable "instance_type" {
  description = "EC2 instance type for the AI Gateway"
  type        = string
  default     = "c6a.4xlarge"
}

# ── Netskope ──────────────────────────────────────────────────────────────────

variable "netskope_server_url" {
  description = "Netskope tenant API v2 URL — overridden by NETSKOPE_SERVER_URL env var"
  type        = string
  default     = ""
}

variable "netskope_api_key" {
  description = "Netskope REST API v2 token — overridden by NETSKOPE_API_KEY env var"
  type        = string
  sensitive   = true
  default     = ""
}

variable "appliance_name" {
  description = "AIG appliance display name — 1 to 15 characters. Must start with the prefix used in the deployment IAM policy (default: 'aig-'). All EC2 resource Name tags derive from this value; changing the prefix requires updating the IAM policy conditions to match."
  type        = string
  default     = "aig-pov"

  validation {
    condition     = length(var.appliance_name) >= 1 && length(var.appliance_name) <= 15
    error_message = "appliance_name must be 1–15 characters (Netskope limit)."
  }
}

variable "appliance_host" {
  description = "IP address or hostname the AIG will be reachable at (registered in the Netskope tenant)"
  type        = string
}

# ── Secrets Manager ───────────────────────────────────────────────────────────

variable "secret_name" {
  description = "Secrets Manager secret name for the AIG bootstrap config"
  type        = string
  default     = "aig/prod/bootstrap"
}
