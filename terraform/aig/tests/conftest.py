"""
Shared pytest fixtures for AIG Terraform integration tests.

Requires a deployed new-vpc-private stack:
  cd terraform/aig/tests && make test-integration

Environment variables:
  AWS_DEFAULT_REGION      — AWS region (default: us-east-1)
  AWS_PROFILE             — AWS profile (optional)
  NETSKOPE_SERVER_URL     — Required only for Netskope enrollment tests
  NETSKOPE_API_KEY        — Required only for Netskope enrollment tests
  APPLIANCE_NAME          — AIG appliance name used in deployment (default: aig-test)
"""

import json
import os
import subprocess

import boto3
import pytest

# Path to the new-vpc-private Terraform root, relative to this file.
TERRAFORM_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "new-vpc-private")
)


@pytest.fixture(scope="session")
def tf_outputs():
    """Parse Terraform outputs from the deployed new-vpc-private stack."""
    result = subprocess.run(
        ["terraform", "output", "-json"],
        cwd=TERRAFORM_DIR,
        capture_output=True,
        text=True,
        check=True,
    )
    raw = json.loads(result.stdout)
    # Unwrap: {"key": {"value": ..., "type": ...}} → {"key": ...}
    return {k: v["value"] for k, v in raw.items()}


@pytest.fixture(scope="session")
def aws_region():
    return os.environ.get("AWS_DEFAULT_REGION", "us-east-1")


@pytest.fixture(scope="session")
def ec2_client(aws_region):
    return boto3.client("ec2", region_name=aws_region)


@pytest.fixture(scope="session")
def iam_client(aws_region):
    return boto3.client("iam", region_name=aws_region)


@pytest.fixture(scope="session")
def secretsmanager_client(aws_region):
    return boto3.client("secretsmanager", region_name=aws_region)


@pytest.fixture(scope="session")
def netskope_session():
    """
    Returns a requests.Session pre-configured with Netskope API credentials.
    Tests that use this fixture are automatically skipped when the environment
    variables are not set.
    """
    server_url = os.environ.get("NETSKOPE_SERVER_URL", "").rstrip("/")
    api_key = os.environ.get("NETSKOPE_API_KEY", "")
    if not server_url or not api_key:
        pytest.skip(
            "NETSKOPE_SERVER_URL and NETSKOPE_API_KEY are not set — skipping Netskope enrollment tests"
        )

    import requests

    session = requests.Session()
    session.headers["Netskope-Api-Token"] = api_key
    # Attach base_url as a custom attribute for convenience in tests.
    session.base_url = server_url
    return session


@pytest.fixture(scope="session")
def appliance_name():
    return os.environ.get("APPLIANCE_NAME", "aig-test")