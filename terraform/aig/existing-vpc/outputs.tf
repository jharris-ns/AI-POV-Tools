output "appliance_id" {
  description = "Netskope AIG appliance UUID"
  value       = netskope_aig_appliance.this.id
}

output "instance_id" {
  description = "EC2 instance ID of the AI Gateway"
  value       = aws_instance.aig.id
}

output "aig_private_ip" {
  description = "Private IP assigned to the AI Gateway instance"
  value       = aws_instance.aig.private_ip
}

output "bootstrap_secret_arn" {
  description = "ARN of the Secrets Manager bootstrap secret"
  value       = aws_secretsmanager_secret.aig_bootstrap.arn
}
