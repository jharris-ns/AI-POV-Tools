# This directory is not a Terraform root.
# Navigate to the deployment option that matches your environment:
#
#   new-vpc-public/   — creates a new VPC with the AIG in a public subnet (EIP)
#                       and the Guardrails GPU instance in a private subnet behind
#                       a NAT Gateway. Deploys both services together and wires
#                       them up automatically via the AIG bootstrap secret.
