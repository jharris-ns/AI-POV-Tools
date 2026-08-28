# Troubleshooting Guide

## Quick Reference

| Component | Log Location | Health Check |
|-----------|-------------|--------------|
| Guardrails Phase 1 | `/var/log/user-data.log` on instance | SSM Parameter `/<prefix>/guardrails-ready` = `healthy` |
| Guardrails Phase 2 | `/var/log/guardrails-phase2.log` on instance | `curl http://10.0.2.10:8080/ping` → `{"status":"Healthy"}` |
| DLPoD | `/var/log/nsbootstrap.log` on instance | `curl -sk https://10.0.2.20/` → HTTP response (any code) |
| AIG | AIG appliance logs via Netskope tenant | Appliance shows "Connected" in Settings → AI Gateway |

---

## Connecting to Instances

All instances are accessible via SSM Session Manager — no SSH, no bastion required for routine access.

```bash
# Guardrails
aws ssm start-session --target $(terraform output -raw guardrails_instance_id) --region us-west-1

# Bastion (if deployed)
aws ssm start-session --target $(terraform output -raw bastion_instance_id) --region us-west-1

# AIG
aws ssm start-session --target $(terraform output -raw aig_instance_id) --region us-west-1
```

---

## Guardrails Issues

### Monitoring Phase 1 and Phase 2 progress

Use SSM Send Command for a quick non-interactive status check (no session needed):

```bash
# One-shot status snapshot
CMDID=$(aws ssm send-command \
  --region us-west-1 \
  --instance-ids $(terraform output -raw guardrails_instance_id) \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["echo === Phase1 ===; tail -3 /var/log/user-data.log 2>/dev/null; echo === Phase2 ===; tail -3 /var/log/guardrails-phase2.log 2>/dev/null; echo === Docker ===; docker ps 2>/dev/null | head -3 || echo no-docker; echo === SSM param ===; aws ssm get-parameter --name /guardrails-dev/guardrails-ready --region us-west-1 --query Parameter.Value --output text 2>/dev/null || echo not-set"]' \
  --query Command.CommandId --output text)
sleep 12
aws ssm get-command-invocation \
  --region us-west-1 --command-id "$CMDID" \
  --instance-id $(terraform output -raw guardrails_instance_id) \
  --query StandardOutputContent --output text
```

For a live interactive tail, open a session:
```bash
aws ssm start-session --target $(terraform output -raw guardrails_instance_id) --region us-west-1
sudo tail -f /var/log/user-data.log          # Phase 1
sudo tail -f /var/log/guardrails-phase2.log  # Phase 2
```

### Phase 1 stalled — dpkg lock

**Symptom:** `/var/log/user-data.log` has only 1–2 lines and stops at `cloud-init status --wait` or `apt-get install` with `Unable to acquire the dpkg frontend lock`.

**Root cause:** Ubuntu 22.04 cloud images run `apt-daily-upgrade` automatically at first boot. The userdata template uses `apt-get -o DPkg::Lock::Timeout=300` to wait up to 5 minutes for the lock — this should resolve on its own.

**If the instance appears completely stuck** (SSM reachable but log not growing after 15+ minutes):
```bash
# Check what's holding the lock
CMDID=$(aws ssm send-command \
  --region us-west-1 \
  --instance-ids <instance-id> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["cloud-init status --long; ps aux | grep -E \"apt|dpkg\" | grep -v grep"]' \
  --query Command.CommandId --output text)
sleep 12
aws ssm get-command-invocation --region us-west-1 \
  --command-id "$CMDID" --instance-id <instance-id> \
  --query StandardOutputContent --output text
```

> **Note:** Do NOT use `cloud-init status --wait` inside a userdata script — the script is itself a cloud-init module, so it deadlocks waiting for itself to finish. The template uses `DPkg::Lock::Timeout` instead.

### Phase 1 stalled — other causes

- NAT Gateway not yet ready (instance created too quickly after NAT GW)
- S3 bucket in wrong region — image download will fail silently
- `image_s3_bucket` or `image_s3_key` typo in tfvars

### Phase 2 stalled (Docker / image load)

```bash
sudo tail -f /var/log/guardrails-phase2.log
sudo systemctl status guardrails-setup.service
```

The S3 image download (`aisecurity-llm.tgz`) is ~15 GB and typically downloads at 100–130 MiB/s (~2 minutes). `docker load` of a 15 GB image takes 3–5 minutes. Total Phase 2 time is typically 15–25 minutes.

### Guardrails health check failing

```bash
# From Guardrails instance or bastion
curl http://10.0.2.10:8080/ping
# Expected: {"status":"Healthy"}

# Check container status
sudo docker ps
sudo docker logs $(sudo docker ps -q)
```

### Stale SSM readiness parameter

If `terraform apply` passes the Guardrails readiness gate instantly on a fresh deploy but Guardrails isn't actually ready, a stale parameter from a previous deployment is the cause. The readiness gate (`null_resource.guardrails_ready`) deletes the parameter before polling, so this should be self-correcting. To manually clear it:

```bash
aws ssm delete-parameter \
  --name "/guardrails-dev/guardrails-ready" \
  --region us-west-1
terraform apply  # re-run; gate will now wait properly
```

---

## DLPoD Issues

### Bootstrap not applied

Check nsbootstrap logs on the DLPoD instance. DLPoD does not support SSM Session Manager by default — connect via bastion SSH:

```bash
ssh -i your-key.pem nsadmin@10.0.2.20   # from bastion
sudo journalctl -u nsbootstrap -f
```

### TLS certificate issues

Verify the cert DLPoD is serving:

```bash
# From bastion
openssl s_client -connect 10.0.2.20:443 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -text | grep -A3 "Subject Alternative"
```

Expected output:
```
subject=O=Netskope POV, CN=dlp.aigw.internal
issuer=O=Netskope POV, CN=Netskope POV DLPoD CA
X509v3 Subject Alternative Name:
    DNS:dlp.aigw.internal, IP Address:10.0.2.20
```

If the issuer is not `Netskope POV DLPoD CA`, DLPoD is serving its built-in cert — the bootstrap dlpaas section was not applied.

### DLPoD not reachable from AIG

Test TLS reachability via bastion:

```bash
# Without cert verification
curl -sk --max-time 5 https://10.0.2.20/ -w "%{http_code}"
# Expected: 404 (service up, root path not mapped)

# With CA cert verification
aws secretsmanager get-secret-value \
  --secret-id aig/prod/bootstrap \
  --region us-west-1 \
  --query SecretString \
  --output text \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['dlp']['certificate'])" \
  > /tmp/dlpod-ca.pem
curl -s --cacert /tmp/dlpod-ca.pem https://10.0.2.20/ -w "%{http_code}"
# Expected: 404
```

---

## AIG Issues

### Appliance shows "Disconnected" in tenant

The AIG bootstrap runs at first boot. Check bootstrap logs on the AIG instance:

```bash
aws ssm start-session --target <aig-instance-id> --region us-west-1
sudo journalctl -u aig-bootstrap -f
# or
sudo cat /var/log/aig-bootstrap.log
```

### DLPoD service registration failing

Error pattern:
```
x509: certificate is valid for dlp.aigw.internal, not
```

**Cause:** The `dlp.host` in the bootstrap secret is a bare IP (`https://10.0.2.20`). The AIG's Go TLS stack cannot extract a hostname from an IP URL, so it validates against an empty string.

**Fix:** `dlp.host` must use the hostname (`https://dlp.aigw.internal`) with Route 53 resolving it to the DLPoD private IP. This is the current configuration — if you see this error, the secret predates the Route 53 fix.

```bash
# Verify current secret content
aws secretsmanager get-secret-value \
  --secret-id aig/prod/bootstrap \
  --region us-west-1 \
  --query SecretString \
  --output text | python3 -m json.tool | grep '"host"'

# Should show:
#   "host": "https://dlp.aigw.internal"   ← correct
#   "host": "https://10.0.2.20"           ← wrong, rebuild needed
```

To fix, taint and rebuild:

```bash
terraform taint aws_secretsmanager_secret_version.aig_bootstrap
terraform taint aws_instance.aig
terraform apply
```

### Enrollment token expired or consumed

Enrollment tokens are single-use and expire after 24 hours. If the AIG fails to enroll after a long delay:

```bash
terraform taint netskope_aig_appliance_enrollment_token.this
terraform taint aws_secretsmanager_secret_version.aig_bootstrap
terraform taint aws_instance.aig
terraform apply
```

---

## Rebuilding Components

### Rebuild AIG only (same appliance, new token)

```bash
terraform taint netskope_aig_appliance_enrollment_token.this
terraform taint aws_secretsmanager_secret_version.aig_bootstrap
terraform taint aws_instance.aig
terraform apply
```

### Full AIG re-registration (new appliance record)

Use when the appliance record in the Netskope tenant is stale or deleted:

```bash
terraform taint netskope_aig_appliance.this
terraform taint netskope_aig_appliance_enrollment_token.this
terraform taint aws_secretsmanager_secret_version.aig_bootstrap
terraform taint aws_instance.aig
terraform apply
```

### Rebuild Guardrails

```bash
terraform taint aws_instance.guardrails
terraform taint null_resource.guardrails_ready  # re-run readiness gate
terraform apply
# This will also recreate null_resource.dlpod_ready and aws_instance.aig
# (because AIG depends on both readiness gates)
```

### Rebuild DLPoD

```bash
terraform taint aws_instance.dlpod
terraform taint null_resource.dlpod_ready
terraform apply
# AIG will also be recreated (depends on dlpod_ready)
```
