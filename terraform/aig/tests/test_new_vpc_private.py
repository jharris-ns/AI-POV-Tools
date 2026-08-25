"""
Layer 2 integration tests for the new-vpc-private AIG Terraform template.

These tests validate real AWS resources deployed by `terraform apply`.
Run via: cd terraform/aig/tests && make test-integration

Resources are looked up by:
  - Terraform outputs (vpc_id, instance_id, bootstrap_secret_arn, appliance_id)
  - Name tags derived from appliance_name (APPLIANCE_NAME env var, default: aig-test)
"""

import json
import time
import urllib.parse

import pytest


# ── VPC ───────────────────────────────────────────────────────────────────────


class TestVPC:
    def test_vpc_exists(self, ec2_client, tf_outputs):
        resp = ec2_client.describe_vpcs(VpcIds=[tf_outputs["vpc_id"]])
        assert len(resp["Vpcs"]) == 1, "VPC must exist"

    def test_vpc_cidr(self, ec2_client, tf_outputs):
        resp = ec2_client.describe_vpcs(VpcIds=[tf_outputs["vpc_id"]])
        assert resp["Vpcs"][0]["CidrBlock"] == "10.0.0.0/16"

    def test_vpc_dns_support(self, ec2_client, tf_outputs):
        # DNS flags are returned by describe_vpc_attribute, not describe_vpcs.
        resp = ec2_client.describe_vpc_attribute(
            VpcId=tf_outputs["vpc_id"], Attribute="enableDnsSupport"
        )
        assert resp["EnableDnsSupport"]["Value"] is True

    def test_vpc_dns_hostnames(self, ec2_client, tf_outputs):
        resp = ec2_client.describe_vpc_attribute(
            VpcId=tf_outputs["vpc_id"], Attribute="enableDnsHostnames"
        )
        assert resp["EnableDnsHostnames"]["Value"] is True


# ── Subnets ───────────────────────────────────────────────────────────────────


class TestSubnets:
    def _find_subnet(self, ec2_client, vpc_id, name_tag):
        resp = ec2_client.describe_subnets(
            Filters=[
                {"Name": "vpc-id", "Values": [vpc_id]},
                {"Name": "tag:Name", "Values": [name_tag]},
            ]
        )
        assert len(resp["Subnets"]) == 1, f"Expected exactly one subnet with Name={name_tag}"
        return resp["Subnets"][0]

    def test_public_subnet_cidr(self, ec2_client, tf_outputs, appliance_name):
        subnet = self._find_subnet(ec2_client, tf_outputs["vpc_id"], f"{appliance_name}-public")
        assert subnet["CidrBlock"] == "10.0.0.0/24"

    def test_private_subnet_cidr(self, ec2_client, tf_outputs, appliance_name):
        subnet = self._find_subnet(ec2_client, tf_outputs["vpc_id"], f"{appliance_name}-private")
        assert subnet["CidrBlock"] == "10.0.1.0/24"

    def test_nat_gateway_in_public_subnet(self, ec2_client, tf_outputs, appliance_name):
        public_subnet = self._find_subnet(
            ec2_client, tf_outputs["vpc_id"], f"{appliance_name}-public"
        )
        resp = ec2_client.describe_nat_gateways(
            Filters=[
                {"Name": "vpc-id", "Values": [tf_outputs["vpc_id"]]},
                {"Name": "subnet-id", "Values": [public_subnet["SubnetId"]]},
                {"Name": "state", "Values": ["available"]},
            ]
        )
        assert len(resp["NatGateways"]) == 1, "NAT Gateway must be in the public subnet"

    def test_ec2_instance_in_private_subnet(self, ec2_client, tf_outputs, appliance_name):
        private_subnet = self._find_subnet(
            ec2_client, tf_outputs["vpc_id"], f"{appliance_name}-private"
        )
        resp = ec2_client.describe_instances(InstanceIds=[tf_outputs["instance_id"]])
        instance = resp["Reservations"][0]["Instances"][0]
        assert instance["SubnetId"] == private_subnet["SubnetId"], (
            "AIG EC2 instance must be in the private subnet"
        )


# ── Route Tables ──────────────────────────────────────────────────────────────


class TestRouteTables:
    def _find_rt(self, ec2_client, vpc_id, name_tag):
        resp = ec2_client.describe_route_tables(
            Filters=[
                {"Name": "vpc-id", "Values": [vpc_id]},
                {"Name": "tag:Name", "Values": [name_tag]},
            ]
        )
        assert len(resp["RouteTables"]) == 1, f"Expected one route table with Name={name_tag}"
        return resp["RouteTables"][0]

    def test_public_route_table_has_igw(self, ec2_client, tf_outputs, appliance_name):
        rt = self._find_rt(ec2_client, tf_outputs["vpc_id"], f"{appliance_name}-public-rt")
        default_routes = [
            r for r in rt["Routes"]
            if r.get("DestinationCidrBlock") == "0.0.0.0/0"
        ]
        assert len(default_routes) == 1, "Public route table must have a 0.0.0.0/0 route"
        assert default_routes[0].get("GatewayId", "").startswith("igw-"), (
            "Public default route must point to an Internet Gateway"
        )

    def test_private_route_table_has_nat(self, ec2_client, tf_outputs, appliance_name):
        rt = self._find_rt(ec2_client, tf_outputs["vpc_id"], f"{appliance_name}-private-rt")
        default_routes = [
            r for r in rt["Routes"]
            if r.get("DestinationCidrBlock") == "0.0.0.0/0"
        ]
        assert len(default_routes) == 1, "Private route table must have a 0.0.0.0/0 route"
        assert default_routes[0].get("NatGatewayId", "").startswith("nat-"), (
            "Private default route must point to a NAT Gateway"
        )


# ── Security Group ────────────────────────────────────────────────────────────


class TestSecurityGroup:
    def _find_sg(self, ec2_client, vpc_id, name_tag):
        resp = ec2_client.describe_security_groups(
            Filters=[
                {"Name": "vpc-id", "Values": [vpc_id]},
                {"Name": "tag:Name", "Values": [name_tag]},
            ]
        )
        assert len(resp["SecurityGroups"]) == 1, f"Expected one SG with Name={name_tag}"
        return resp["SecurityGroups"][0]

    def test_ingress_allows_https(self, ec2_client, tf_outputs, appliance_name):
        sg = self._find_sg(ec2_client, tf_outputs["vpc_id"], f"{appliance_name}-sg")
        https_rules = [
            r for r in sg["IpPermissions"]
            if r["FromPort"] == 443 and r["ToPort"] == 443 and r["IpProtocol"] == "tcp"
        ]
        assert len(https_rules) == 1, "Security group must have exactly one ingress rule on TCP 443"

    def test_egress_allows_https(self, ec2_client, tf_outputs, appliance_name):
        sg = self._find_sg(ec2_client, tf_outputs["vpc_id"], f"{appliance_name}-sg")
        https_egress = [
            r for r in sg["IpPermissionsEgress"]
            if r["FromPort"] == 443 and r["ToPort"] == 443 and r["IpProtocol"] == "tcp"
        ]
        assert len(https_egress) == 1, "Security group must allow egress on TCP 443"

    def test_egress_allows_dns(self, ec2_client, tf_outputs, appliance_name):
        sg = self._find_sg(ec2_client, tf_outputs["vpc_id"], f"{appliance_name}-sg")
        dns_egress = [
            r for r in sg["IpPermissionsEgress"]
            if r["FromPort"] == 53 and r["ToPort"] == 53
        ]
        protocols = {r["IpProtocol"] for r in dns_egress}
        assert "tcp" in protocols, "Security group must allow DNS egress on TCP 53"
        assert "udp" in protocols, "Security group must allow DNS egress on UDP 53"


# ── IAM ───────────────────────────────────────────────────────────────────────


class TestIAM:
    def test_role_trusts_ec2(self, iam_client, appliance_name):
        role_name = f"{appliance_name}-role"
        resp = iam_client.get_role(RoleName=role_name)
        trust = json.loads(urllib.parse.unquote(
            resp["Role"]["AssumeRolePolicyDocument"]
            if isinstance(resp["Role"]["AssumeRolePolicyDocument"], str)
            else json.dumps(resp["Role"]["AssumeRolePolicyDocument"])
        ))
        principals = [
            stmt.get("Principal", {})
            for stmt in trust.get("Statement", [])
        ]
        services = []
        for p in principals:
            svc = p.get("Service", [])
            services.extend([svc] if isinstance(svc, str) else svc)
        assert "ec2.amazonaws.com" in services, (
            "IAM role trust policy must allow ec2.amazonaws.com to assume the role"
        )

    def test_inline_policy_grants_secret_access(self, iam_client, tf_outputs, appliance_name):
        role_name = f"{appliance_name}-role"
        policy_name = f"{appliance_name}-read-bootstrap-secret"
        resp = iam_client.get_role_policy(RoleName=role_name, PolicyName=policy_name)
        # get_role_policy returns the policy document URL-encoded.
        policy_doc = json.loads(urllib.parse.unquote(resp["PolicyDocument"]))
        secret_arn = tf_outputs["bootstrap_secret_arn"]

        def _as_list(value):
            return value if isinstance(value, list) else [value]

        for stmt in policy_doc.get("Statement", []):
            actions = _as_list(stmt.get("Action", []))
            resources = _as_list(stmt.get("Resource", []))
            if (
                "secretsmanager:GetSecretValue" in actions
                and secret_arn in resources
                and stmt.get("Effect") == "Allow"
            ):
                return  # Found the expected statement
        pytest.fail(
            f"Inline policy {policy_name} must grant secretsmanager:GetSecretValue on {secret_arn}"
        )


# ── Secrets Manager ───────────────────────────────────────────────────────────


class TestSecretsManager:
    def test_secret_exists(self, secretsmanager_client, tf_outputs):
        resp = secretsmanager_client.describe_secret(
            SecretId=tf_outputs["bootstrap_secret_arn"]
        )
        assert resp["ARN"] == tf_outputs["bootstrap_secret_arn"]

    def test_secret_contains_enrollment_token(self, secretsmanager_client, tf_outputs):
        resp = secretsmanager_client.get_secret_value(
            SecretId=tf_outputs["bootstrap_secret_arn"]
        )
        secret = json.loads(resp["SecretString"])
        assert secret.get("bootstrap") is True, "Secret must have bootstrap=true"
        assert "enrollment_token" in secret and secret["enrollment_token"], (
            "Secret must contain a non-empty enrollment_token"
        )


# ── EC2 Instance ──────────────────────────────────────────────────────────────


class TestEC2Instance:
    def _get_instance(self, ec2_client, tf_outputs):
        resp = ec2_client.describe_instances(InstanceIds=[tf_outputs["instance_id"]])
        return resp["Reservations"][0]["Instances"][0]

    def test_instance_running(self, ec2_client, tf_outputs):
        instance = self._get_instance(ec2_client, tf_outputs)
        assert instance["State"]["Name"] == "running", "AIG EC2 instance must be running"

    def test_instance_fixed_private_ip(self, ec2_client, tf_outputs):
        instance = self._get_instance(ec2_client, tf_outputs)
        assert instance["PrivateIpAddress"] == "10.0.1.10", (
            "AIG instance must have fixed private IP 10.0.1.10"
        )
        assert tf_outputs["aig_private_ip"] == "10.0.1.10"

    def test_instance_has_iam_profile(self, ec2_client, tf_outputs, appliance_name):
        instance = self._get_instance(ec2_client, tf_outputs)
        profile_arn = instance.get("IamInstanceProfile", {}).get("Arn", "")
        assert f"{appliance_name}-instance-profile" in profile_arn, (
            f"EC2 instance must use the {appliance_name}-instance-profile IAM profile"
        )

    def test_instance_ami(self, ec2_client, tf_outputs):
        instance = self._get_instance(ec2_client, tf_outputs)
        # Verify the instance was launched from an AIG AMI (non-empty AMI ID).
        assert instance["ImageId"].startswith("ami-"), "Instance must have a valid AMI ID"


# ── Netskope Enrollment ───────────────────────────────────────────────────────


class TestNetskopeEnrollment:
    """
    Polls the Netskope API until the AIG appliance reports status=connected.

    Skipped automatically when NETSKOPE_SERVER_URL / NETSKOPE_API_KEY are not set.
    Allow up to 15 minutes for enrollment to complete after the EC2 instance boots.
    """

    POLL_INTERVAL_SEC = 30
    TIMEOUT_SEC = 15 * 60  # 15 minutes

    @pytest.mark.timeout(1020)  # pytest-timeout: 17 minutes (buffer above TIMEOUT_SEC)
    def test_appliance_connected(self, netskope_session, tf_outputs):
        appliance_id = tf_outputs["appliance_id"]
        deadline = time.monotonic() + self.TIMEOUT_SEC

        while time.monotonic() < deadline:
            resp = netskope_session.get(f"{netskope_session.base_url}/aig/appliances")
            resp.raise_for_status()
            for appliance in resp.json().get("elements", []):
                if appliance.get("id") == appliance_id:
                    status = appliance.get("status")
                    if status == "connected":
                        return
                    # Any non-connected status: keep polling.
                    break
            time.sleep(self.POLL_INTERVAL_SEC)

        pytest.fail(
            f"AIG appliance {appliance_id} did not reach status=connected within "
            f"{self.TIMEOUT_SEC // 60} minutes"
        )