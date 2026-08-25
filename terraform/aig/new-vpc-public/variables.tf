# ── AWS ───────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy the AI Gateway"
  type        = string
  default     = "us-west-1"
}

variable "availability_zone" {
  description = "Availability zone for the public subnet"
  type        = string
  default     = "us-west-1b"
}

# ── VPC / Networking ──────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the new VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnet"
  type        = string
  default     = "10.0.0.0/24"
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks permitted to reach the AI Gateway on port 443"
  type        = list(string)
  default     = ["0.0.0.0/0"]
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

variable "key_name" {
  description = "EC2 key pair name for SSH access (optional)"
  type        = string
  default     = null
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

# ── Secrets Manager ───────────────────────────────────────────────────────────

variable "secret_name" {
  description = "Secrets Manager secret name for the AIG bootstrap config"
  type        = string
  default     = "aig/prod/bootstrap"
}
