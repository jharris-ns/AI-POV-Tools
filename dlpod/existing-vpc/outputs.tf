output "instance_id" {
  description = "EC2 instance ID of the DLPoD appliance"
  value       = aws_instance.dlpod.id
}

output "private_ip" {
  description = "Private IP assigned to the DLPoD instance"
  value       = aws_instance.dlpod.private_ip
}

output "dlp_host" {
  description = "DLP host URL to pass to the AIG template as dlp_host. The AIG bootstrap secret uses this URL to forward DLP inspection traffic to DLPoD. Value: https://<dlpod_hostname>"
  value       = "https://${var.dlpod_hostname}"
}

output "ca_cert_pem" {
  description = "DLPoD CA certificate in PEM format. Pass this to the AIG template as dlp_ca_cert_pem — the AIG uses it as a trust anchor to verify DLPoD's TLS certificate chain. Retrieve with: terraform output -raw ca_cert_pem"
  value       = tls_self_signed_cert.dlpod_ca.cert_pem
}

output "security_group_id" {
  description = "Security group ID of the DLPoD instance. After deploying the AIG, you can optionally replace the CIDR-based ingress rule with a security group reference for tighter scoping."
  value       = aws_security_group.dlpod.id
}

output "route53_zone_id" {
  description = "Route 53 private hosted zone ID resolving dlpod_hostname to the DLPoD private IP. If your AIG is in a different VPC, associate that VPC with this zone so the AIG can resolve the hostname."
  value       = aws_route53_zone.dlpod.zone_id
}
