# ── AWS ───────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region where the existing VPC lives"
  type        = string
  default     = "us-east-1"
}

# ── Existing VPC ──────────────────────────────────────────────────────────────

variable "vpc_id" {
  description = "ID of the existing VPC to deploy DLPoD into"
  type        = string
}

variable "subnet_id" {
  description = "ID of the existing subnet for the DLPoD instance. The subnet must have outbound internet access (via NAT Gateway or IGW route) for bootstrap to complete."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the existing VPC. Used to determine the VPC DNS resolver address (base address + 2) in the DLPoD bootstrap config."
  type        = string
  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "Must be a valid IPv4 CIDR block."
  }
}

variable "allowed_inspection_cidr" {
  description = "CIDR block allowed to reach DLPoD on TCP port 443. Set to the subnet or CIDR containing your AIG instance. Restrict as tightly as possible — the AIG is the only client that should reach this port."
  type        = string
  validation {
    condition     = can(cidrhost(var.allowed_inspection_cidr, 0))
    error_message = "Must be a valid IPv4 CIDR block."
  }
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed inbound on port 22. Default (127.0.0.1/32) effectively disables direct SSH — DLPoD does not support SSM Session Manager; use a bastion or the appliance console instead."
  type        = string
  default     = "127.0.0.1/32"
  validation {
    condition     = can(cidrhost(var.allowed_ssh_cidr, 0))
    error_message = "Must be a valid IPv4 CIDR block."
  }
}

# ── Project ───────────────────────────────────────────────────────────────────

variable "project" {
  description = "Short project identifier used in resource names and tags"
  type        = string
  default     = "netskope"
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.project))
    error_message = "Must be lowercase alphanumeric and hyphens, starting with a letter or digit."
  }
}

variable "environment" {
  description = "Deployment environment used in resource names and tags"
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be dev, staging, or prod."
  }
}

# ── DLPoD EC2 ─────────────────────────────────────────────────────────────────

variable "dlpod_ami_id" {
  description = "AMI ID for the Netskope DLPoD appliance. AMI IDs are region-specific — obtain from Netskope. Default is us-west-1; update for other regions."
  type        = string
  default     = "ami-0b3a14615c7e7944e"
}

variable "dlpod_instance_type" {
  description = "EC2 instance type for DLPoD. c5d.4xlarge (local NVMe SSD) speeds up nsbootstrap initialisation and is recommended. c5a.4xlarge is the AMD equivalent where available."
  type        = string
  default     = "c5d.4xlarge"
}

variable "dlpod_private_ip" {
  description = "Static private IP to assign to the DLPoD instance. Must be a free address within the subnet CIDR. The TLS certificate SAN is generated from this IP — changing it after apply requires replacing the instance."
  type        = string
  validation {
    condition     = can(cidrhost("${var.dlpod_private_ip}/32", 0))
    error_message = "Must be a valid IPv4 address."
  }
}

variable "dlpod_hostname" {
  description = "Hostname for DLPoD. Used as the TLS certificate CN and DNS SAN, the Route 53 A record name, and in the AIG bootstrap secret as the DLP host URL (https://<hostname>). Must match what the AIG template uses."
  type        = string
  default     = "dlp.aigw.internal"
}

variable "dlpod_licensekey" {
  description = "Netskope license key for the DLPoD appliance"
  type        = string
  sensitive   = true
}

variable "dlpod_ssh_public_key" {
  description = "SSH public key to provision for the nsadmin user on DLPoD. Optional — leave empty to skip. Format: 'ssh-rsa AAAA...'"
  type        = string
  default     = ""
}

variable "key_pair_name" {
  description = "EC2 key pair name for SSH access to DLPoD. Optional — DLPoD does not support SSM Session Manager, so a key pair or bastion is needed for shell access."
  type        = string
  default     = ""
}
