# Makefile for AIG Terraform regression tests
#
# Usage:
#   make install          Install Python dependencies
#   make test-static      Layer 1: plan-only tests (no credentials needed)
#   make test-integration Layer 2: deploy, test, destroy (requires AWS credentials)
#   make test-all         Run both layers
#   make clean            Destroy infra and remove local state
#
# Required for test-integration:
#   AWS credentials via environment (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY)
#   or an IAM role / AWS profile (AWS_PROFILE).
#
# Optional overrides:
#   AMI_ID            Override the AIG AMI (default: variable default in variables.tf)
#   AWS_REGION        Override the deployment region (default: us-west-1)
#   APPLIANCE_NAME    Name used to derive resource tags (default: aig-test)
#   SKIP_ENROLLMENT=1 Skip the Netskope enrollment poll (use with non-AIG AMIs)

TF_DIR        := ../new-vpc-private
FIXTURES      := tests/fixtures/new-vpc-private.tfvars
TF_DIR_PUBLIC := ../new-vpc-public
FIXTURES_PUBLIC := ../new-vpc-public/tests/fixtures/new-vpc-public.tfvars
APPLIANCE_NAME ?= aig-test
AWS_REGION    ?= us-west-1

# Extra -var flags for integration runs. AMI_ID is optional; variables.tf default is used if unset.
TF_EXTRA_VARS ?=
ifdef AMI_ID
  TF_EXTRA_VARS += -var="aig_ami_id=$(AMI_ID)"
endif

.PHONY: install validate plan test-static test-integration test-integration-public test-all clean

install:
	pip install -r requirements.txt

validate:
	terraform -chdir=$(TF_DIR) validate

plan:
	terraform -chdir=$(TF_DIR) init -input=false
	terraform -chdir=$(TF_DIR) plan \
	  -var-file=$(FIXTURES) \
	  $(TF_EXTRA_VARS)

# ── Layer 1: plan-only tests (mock providers, no credentials) ─────────────────

test-static:
	terraform -chdir=$(TF_DIR) init -input=false
	terraform -chdir=$(TF_DIR) test

# ── Layer 2: integration tests (real AWS deployment) ─────────────────────────

test-integration:
	@echo "==> Initialising Terraform..."
	terraform -chdir=$(TF_DIR) init -input=false
	@echo "==> Deploying new-vpc-private stack..."
	terraform -chdir=$(TF_DIR) apply -auto-approve \
	  -var-file=$(FIXTURES) \
	  $(TF_EXTRA_VARS); \
	APPLY_EXIT=$$?; \
	if [ $$APPLY_EXIT -ne 0 ]; then \
	  echo "==> Apply failed — destroying any partial resources..."; \
	  terraform -chdir=$(TF_DIR) destroy -auto-approve \
	    -var-file=$(FIXTURES) \
	    $(TF_EXTRA_VARS); \
	  exit $$APPLY_EXIT; \
	fi
	@echo "==> Running integration tests..."
	APPLIANCE_NAME=$(APPLIANCE_NAME) AWS_DEFAULT_REGION=$(AWS_REGION) SKIP_ENROLLMENT=$(SKIP_ENROLLMENT) \
	  pytest test_new_vpc_private.py -v \
	    --timeout=1200 \
	    --json-report \
	    --json-report-file=test-results.json; \
	PYTEST_EXIT=$$?; \
	echo "==> Destroying stack (always runs)..."; \
	terraform -chdir=$(TF_DIR) destroy -auto-approve \
	  -var-file=$(FIXTURES) \
	  $(TF_EXTRA_VARS); \
	exit $$PYTEST_EXIT

# ── Layer 2: integration tests for new-vpc-public ─────────────────────────────

test-integration-public:
	@echo "==> Initialising Terraform (new-vpc-public)..."
	terraform -chdir=$(TF_DIR_PUBLIC) init -input=false
	@echo "==> Deploying new-vpc-public stack..."
	terraform -chdir=$(TF_DIR_PUBLIC) apply -auto-approve \
	  -var-file=$(FIXTURES_PUBLIC) \
	  $(TF_EXTRA_VARS); \
	APPLY_EXIT=$$?; \
	if [ $$APPLY_EXIT -ne 0 ]; then \
	  echo "==> Apply failed — destroying any partial resources..."; \
	  terraform -chdir=$(TF_DIR_PUBLIC) destroy -auto-approve \
	    -var-file=$(FIXTURES_PUBLIC) \
	    $(TF_EXTRA_VARS); \
	  exit $$APPLY_EXIT; \
	fi
	@echo "==> Running integration tests (new-vpc-public)..."
	APPLIANCE_NAME=$(APPLIANCE_NAME) AWS_DEFAULT_REGION=$(AWS_REGION) SKIP_ENROLLMENT=$(SKIP_ENROLLMENT) \
	  TF_DIR=$(abspath $(TF_DIR_PUBLIC)) \
	  pytest test_new_vpc_public.py -v \
	    --timeout=1200 \
	    --json-report \
	    --json-report-file=test-results-public.json; \
	PYTEST_EXIT=$$?; \
	echo "==> Destroying stack (always runs)..."; \
	terraform -chdir=$(TF_DIR_PUBLIC) destroy -auto-approve \
	  -var-file=$(FIXTURES_PUBLIC) \
	  $(TF_EXTRA_VARS); \
	exit $$PYTEST_EXIT

# ── Both layers ───────────────────────────────────────────────────────────────

test-all: test-static test-integration

# ── Cleanup ───────────────────────────────────────────────────────────────────

clean:
	-terraform -chdir=$(TF_DIR) destroy -auto-approve \
	  -var-file=$(FIXTURES) \
	  $(TF_EXTRA_VARS) 2>/dev/null || true
	rm -rf $(TF_DIR)/.terraform $(TF_DIR)/.terraform.lock.hcl
	rm -f $(TF_DIR)/terraform.tfstate $(TF_DIR)/terraform.tfstate.backup
	rm -f test-results.json