"""
Layer 2 integration tests for the existing-vpc AIG Terraform template.

These tests validate real AWS resources deployed by `terraform apply`.
Run via: cd terraform/aig/tests && make test-integration-existing

The existing-vpc template does NOT create VPC/subnet/networking — it deploys
only IAM, Secrets Manager, SG, and EC2 into a pre-existing VPC. A minimal
test-network fixture provides the VPC and subnet.

Resources are looked up by:
  - Terraform outputs (instance_id, bootstrap_secret_arn, appliance_id, aig_private_ip)
  - Name tags derived from appliance_name (APPLIANCE_NAME env var, default: aig-test)
  - VPC_ID env var (passed by Makefile from test-network outputs)
"""

import json
import os
import time
import urllib.parse

import pytest


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

    @pytest.fixture(scope="class")
    def vpc_id(self):
        vpc_id = os.environ.get("VPC_ID", "")
        assert vpc_id, "VPC_ID env var must be set (passed by Makefile from test-network output)"
        return vpc_id

    def test_ingress_allows_https(self, ec2_client, vpc_id, appliance_name):
        sg = self._find_sg(ec2_client, vpc_id, f"{appliance_name}-sg")
        https_rules = [
            r for r in sg["IpPermissions"]
            if r["FromPort"] == 443 and r["ToPort"] == 443 and r["IpProtocol"] == "tcp"
        ]
        assert len(https_rules) == 1, "Security group must have exactly one ingress rule on TCP 443"

    def test_egress_allows_all(self, ec2_client, vpc_id, appliance_name):
        sg = self._find_sg(ec2_client, vpc_id, f"{appliance_name}-sg")
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

    def test_instance_private_ip_matches_output(self, ec2_client, tf_outputs):
        instance = self._get_instance(ec2_client, tf_outputs)
        assert instance["PrivateIpAddress"] == tf_outputs["aig_private_ip"], (
            "Instance private IP must match the aig_private_ip output"
        )

    def test_instance_in_correct_subnet(self, ec2_client, tf_outputs):
        instance = self._get_instance(ec2_client, tf_outputs)
        subnet_id = os.environ.get("SUBNET_ID", "")
        assert subnet_id, "SUBNET_ID env var must be set"
        assert instance["SubnetId"] == subnet_id, (
            "AIG instance must be deployed in the supplied subnet"
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
    TIMEOUT_SEC = 15 * 60

    @pytest.mark.timeout(1020)
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
                        if appliance.get("status") == "connected":
                            return
                        break
            except _requests.exceptions.RequestException:
                pass
            time.sleep(self.POLL_INTERVAL_SEC)

        pytest.fail(
            f"AIG appliance {appliance_id} did not reach status=connected within "
            f"{self.TIMEOUT_SEC // 60} minutes"
        )
