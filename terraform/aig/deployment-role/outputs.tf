output "role_arn" {
  description = "ARN of the AIG deployment role — assume this role before running terraform apply in any deployment template"
  value       = aws_iam_role.aig_deployment.arn
}

output "role_name" {
  description = "Name of the AIG deployment role"
  value       = aws_iam_role.aig_deployment.name
}

output "policy_arn" {
  description = "ARN of the AIG deployment policy"
  value       = aws_iam_policy.aig_deployment.arn
}
