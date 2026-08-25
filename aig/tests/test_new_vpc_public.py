"""
Layer 2 integration tests for the new-vpc-public AIG Terraform template.

These tests validate real AWS resources deployed by `terraform apply`.
Run via: cd aig/tests && make test-integration-public

Resources are looked up by:
  - Terraform outputs (vpc_id, instance_id, bootstrap_secret_arn, appliance_id, public_ip)
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
        resp = ec2_client.describe_vpc_attribute(
            VpcId=tf_outputs["vpc_id"], Attribute="enableDnsSupport"
        )
        assert resp["EnableDnsSupport"]["Value"] is True

    def test_vpc_dns_hostnames(self, ec2_client, tf_outputs):
        resp = ec2_client.describe_vpc_attribute(
            VpcId=tf_outputs["vpc_id"], Attribute="enableDnsHostnames"
        )
        assert resp["EnableDnsHostnames"]["Value"] is True


# ── Subnet ────────────────────────────────────────────────────────────────────


class TestSubnet:
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

    def test_ec2_instance_in_public_subnet(self, ec2_client, tf_outputs, appliance_name):
        public_subnet = self._find_subnet(
            ec2_client, tf_outputs["vpc_id"], f"{appliance_name}-public"
        )
        resp = ec2_client.describe_instances(InstanceIds=[tf_outputs["instance_id"]])
        instance = resp["Reservations"][0]["Instances"][0]
        assert instance["SubnetId"] == public_subnet["SubnetId"], (
            "AIG EC2 instance must be in the public subnet"
        )

    def test_no_private_subnet(self, ec2_client, tf_outputs, appliance_name):
        resp = ec2_client.describe_subnets(
            Filters=[
                {"Name": "vpc-id", "Values": [tf_outputs["vpc_id"]]},
                {"Name": "tag:Name", "Values": [f"{appliance_name}-private"]},
            ]
        )
        assert len(resp["Subnets"]) == 0, "new-vpc-public must not have a private subnet"


# ── Route Table ───────────────────────────────────────────────────────────────


class TestRouteTable:
    def test_public_route_table_has_igw(self, ec2_client, tf_outputs, appliance_name):
        resp = ec2_client.describe_route_tables(
            Filters=[
                {"Name": "vpc-id", "Values": [tf_outputs["vpc_id"]]},
                {"Name": "tag:Name", "Values": [f"{appliance_name}-rt"]},
            ]
        )
        assert len(resp["RouteTables"]) == 1, f"Expected one route table with Name={appliance_name}-rt"
        rt = resp["RouteTables"][0]
        default_routes = [
            r for r in rt["Routes"]
            if r.get("DestinationCidrBlock") == "0.0.0.0/0"
        ]
        assert len(default_routes) == 1, "Route table must have a 0.0.0.0/0 route"
        assert default_routes[0].get("GatewayId", "").startswith("igw-"), (
            "Default route must point to an Internet Gateway"
        )


# ── Elastic IP ────────────────────────────────────────────────────────────────


class TestElasticIP:
    def test_eip_associated_with_instance(self, ec2_client, tf_outputs):
        public_ip = tf_outputs["public_ip"]
        resp = ec2_client.describe_addresses(
            Filters=[{"Name": "public-ip", "Values": [public_ip]}]
        )
        assert len(resp["Addresses"]) == 1, f"EIP {public_ip} must exist"
        addr = resp["Addresses"][0]
        assert addr.get("InstanceId") == tf_outputs["instance_id"], (
            "EIP must be associated with the AIG EC2 instance"
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

    def test_egress_allows_all(self, ec2_client, tf_outputs, appliance_name):
        sg = self._find_sg(ec2_client, tf_outputs["vpc_id"], f"{appliance_name}-sg")
        all_egress = [
            r for r in sg["IpPermissionsEgress"]
            if r["IpProtocol"] == "-1"
            and any(ip.get("CidrIp") == "0.0.0.0/0" for ip in r.get("IpRanges", []))
        ]
        assert len(all_egress) == 1, "Security group must allow all outbound traffic"


# ── IAM ───────────────────────────────────────────────────────────────────────


class TestIAM:
    def test_role_trusts_ec2(self, iam_client, appliance_name):
        role_name = f"{appliance_name}-role"
        resp = iam_client.get_role(RoleName=role_name)
        raw = resp["Role"]["AssumeRolePolicyDocument"]
        trust = raw if isinstance(raw, dict) else json.loads(urllib.parse.unquote(raw))
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
        raw = resp["PolicyDocument"]
        policy_doc = raw if isinstance(raw, dict) else json.loads(urllib.parse.unquote(raw))
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
                return
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

    def test_instance_has_public_ip(self, ec2_client, tf_outputs):
        instance = self._get_instance(ec2_client, tf_outputs)
        assert instance.get("PublicIpAddress") == tf_outputs["public_ip"], (
            "AIG instance public IP must match the allocated EIP"
        )

    def test_instance_has_iam_profile(self, ec2_client, tf_outputs, appliance_name):
        instance = self._get_instance(ec2_client, tf_outputs)
        profile_arn = instance.get("IamInstanceProfile", {}).get("Arn", "")
        assert f"{appliance_name}-instance-profile" in profile_arn, (
            f"EC2 instance must use the {appliance_name}-instance-profile IAM profile"
        )

    def test_instance_ami(self, ec2_client, tf_outputs):
        instance = self._get_instance(ec2_client, tf_outputs)
        assert instance["ImageId"].startswith("ami-"), "Instance must have a valid AMI ID"

    def test_instance_key_pair(self, ec2_client, tf_outputs):
        instance = self._get_instance(ec2_client, tf_outputs)
        assert instance.get("KeyName"), "AIG instance must have an SSH key pair associated"


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
        import requests as _requests

        appliance_id = tf_outputs["appliance_id"]
        deadline = time.monotonic() + self.TIMEOUT_SEC

        while time.monotonic() < deadline:
            try:
                resp = netskope_session.get(
                    f"{netskope_session.base_url}/aig/appliances",
                    timeout=30,
                )
                resp.raise_for_status()
                for appliance in resp.json().get("elements", []):
                    if appliance.get("id") == appliance_id:
                        status = appliance.get("status")
                        if status == "connected":
                            return
                        break
            except _requests.exceptions.RequestException:
                pass
            time.sleep(self.POLL_INTERVAL_SEC)

        pytest.fail(
            f"AIG appliance {appliance_id} did not reach status=connected within "
            f"{self.TIMEOUT_SEC // 60} minutes"
        )
