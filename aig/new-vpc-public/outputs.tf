output "appliance_id" {
  description = "Netskope AIG appliance UUID"
  value       = netskope_aig_appliance.this.id
}

output "instance_id" {
  description = "EC2 instance ID of the AI Gateway"
  value       = aws_instance.aig.id
}

output "public_ip" {
  description = "Elastic IP assigned to the AI Gateway"
  value       = aws_eip.aig.public_ip
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "bootstrap_secret_arn" {
  description = "ARN of the Secrets Manager bootstrap secret"
  value       = aws_secretsmanager_secret.aig_bootstrap.arn
}
