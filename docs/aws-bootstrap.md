# AWS account and Terraform bootstrap

Use separate staging and production accounts under AWS Organizations in Mumbai (`ap-south-1`). This procedure requires a privileged operator and must not store long-lived AWS credentials in GitHub.

## Per-account prerequisites

1. Require MFA for privileged operators and establish a break-glass role with monitored use.
2. Create a versioned, encrypted Terraform-state bucket with public access blocked, dedicated KMS encryption, and S3 lockfile support.
3. Create GitHub's OIDC provider and a temporary bootstrap role restricted to `tcbhagat/challanse`, protected `main`, and the matching GitHub environment.
4. Issue the private-origin ACM certificate and configure Cloudflare Tunnel; never expose an unrestricted public origin.
5. Supply an operator-approved monthly budget and business-hours alarm email.
6. Create a separate backup account/vault and permit only recovery-copy operations from the workload account.

## Initial staging apply

```bash
terraform -chdir=infra/terraform/staging init \
  -backend-config="bucket=<staging-state-bucket>" \
  -backend-config="region=ap-south-1" \
  -backend-config="kms_key_id=<staging-state-kms-arn>" \
  -backend-config="use_lockfile=true"

terraform -chdir=infra/terraform/staging plan \
  -var="container_image=<immutable-ecr-uri>@sha256:<digest>" \
  -var="adot_collector_image=<immutable-adot-image>@sha256:<digest>" \
  -var="cloudflared_image=<immutable-cloudflared-image>@sha256:<digest>" \
  -var="certificate_arn=<staging-acm-arn>" \
  -var="terraform_state_bucket_arn=arn:aws:s3:::<staging-state-bucket>" \
  -var="expected_aws_account_id=<staging-account-id>" \
  -var="certificate_arn=<staging-acm-arn>" \
  -var="backup_destination_vault_arn=<backup-vault-arn>" \
  -var="play_integrity_cloud_project_number=<project-number>" \
  -var="monthly_budget_usd=225" \
  -var="budget_email=<primary-operator-email>" \
  -var="secondary_budget_email=<secondary-operator-email>" \
  -var="github_oidc_provider_arn=<staging-oidc-provider-arn>" \
  -var="services_enabled=false"
```

Review and apply the saved plan. The ALB listener must use TLS 1.2 or newer and remain reachable only from the Cloudflare Tunnel security group. Run `./scripts/go-live.sh configure-tunnel-origin` with Terraform's `private_origin_url` output, then verify Cloudflare records `originServerName=api.challanse.constrovet.com` and `noTLSVerify=false`. Run migrations as a private one-off ECS task, populate active/next HMAC and Access values through the guarded CLI, then enable services only after health and readiness pass.

## Production bootstrap

Repeat with `infra/terraform/production` in the production account. Production uses two NAT gateways, two API tasks, two baseline workers plus queue-depth autoscaling, Multi-AZ PostgreSQL, deletion protection, continuous recovery, and cross-account backup copies.

Use `monthly_budget_usd=350` for production and maintain the separate USD 50 recovery-account allowance documented in `pilot-budget.md`. Do not raise these values without written budget reapproval. Both operator addresses must confirm AWS Budget subscriptions at 50%, 70%, 90%, and 100%.

The generated GitHub deploy role is service-family scoped inside the dedicated environment account and cannot modify itself. Initial role creation or policy changes require the privileged bootstrap operator. After the protected workflow assumes the generated role successfully, remove the temporary bootstrap role.

Keep `services_enabled=false`, `AWS_ENRICHMENT_BOOTSTRAPPED=false`, and `PILOT_DEPLOY_ENABLED=false` until:

- state encryption/locking and account-ID guards are verified;
- immutable image scans, SBOM, and provenance pass;
- runtime secret contains database roles, device pepper, tenant-context HMAC, active/next directional keys, Access credentials, and Play Integrity configuration;
- all migrations complete;
- queue alarms, budget alarms, backup copies, restore evidence, staging acceptance, and Android field acceptance pass.

## Required evidence

- Terraform format, validation, security scan, speculative plan, and drift result.
- PostgreSQL PITR and S3 recovery into isolated infrastructure, including timestamps and application checks.
- ECS failed-deployment rollback, queue-depth scaling, worker termination, DLQ movement, and guarded replay.
- API, database, queue, certificate, upload-failure, and budget alarm delivery.
- Private-origin TLS validation, isolated tunnel task role, VPC flow-log delivery, and reviewed Cloudflare Tunnel egress exception.
- RLS direct-database and application-level two-tenant denial.
- Account IDs, plan hashes, workflow runs, image digests, migration IDs, restore timestamps, and acceptance hashes.

Do not infer live infrastructure, 99.5% availability, RPO, RTO, certification, or legal compliance from repository code. Those claims require recorded production evidence and contractual review.
