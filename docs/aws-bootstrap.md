# AWS account and Terraform bootstrap

This is an operator procedure, not an automated AWS Organizations migration. Use separate staging and production accounts in AWS Mumbai (`ap-south-1`). Do not place long-lived AWS access keys in GitHub.

## Per-account prerequisites

1. Create the account under AWS Organizations and require MFA for privileged operators.
2. Create a versioned, encrypted S3 Terraform-state bucket with public access blocked and a dedicated KMS key.
3. Create the GitHub OIDC provider for `token.actions.githubusercontent.com` and a temporary bootstrap role restricted to `tcbhagat/challanse` protected `main` and the matching GitHub environment.
4. Request and validate an ACM certificate for a dedicated enrichment origin hostname. Put that hostname behind Cloudflare Access with a service-token policy; do not expose it in public navigation.
5. Set an operator-approved monthly AWS budget and notification email. Cost values are intentionally not committed.

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
  -var="certificate_arn=<staging-acm-arn>" \
  -var="monthly_budget_usd=<approved-number>" \
  -var="budget_email=<operator-email>" \
  -var="github_oidc_provider_arn=<staging-oidc-provider-arn>" \
  -var="services_enabled=false"
```

Review and apply the saved plan. The ADOT collector image must be an operator-reviewed immutable digest; it exports traces to AWS X-Ray and metrics to CloudWatch. Capture the ECR repository, runtime secret ARN, DLQ URL, ALB DNS name, and generated GitHub deployment role. Populate directional active/next HMAC keys and Access service credentials only through the guarded CLI. Apply PostgreSQL migrations as a one-off private ECS task before enabling services.

## Production bootstrap

Repeat in `infra/terraform/production` using the production account, state bucket, KMS key, certificate, and budget. Production creates two NAT gateways, a Multi-AZ RDS instance, and enables RDS/ALB deletion protection. Keep `services_enabled=false` and `AWS_ENRICHMENT_BOOTSTRAPPED=false` until:

- state locking and encryption are verified;
- the immutable image scan passes;
- runtime secret contains database, active/next HMAC, and Access values;
- migrations succeed;
- staging acceptance and backup restore evidence are complete.

Then run `configure-aws` and `configure-enrichment`. The generated GitHub OIDC deployment role is account-scoped and intentionally powerful enough to maintain this isolated stack; review its policy before use. Remove the temporary bootstrap role after the protected workflow successfully assumes the generated role.

## Required evidence

- Terraform format, validation, security scan, speculative plan, and drift result.
- RDS point-in-time restore to an isolated subnet and application read check.
- ECS failed-deployment rollback and health-check evidence.
- SQS duplicate delivery, visibility extension, DLQ movement, and guarded replay evidence.
- Budget alarm delivery and CloudWatch log/metric visibility.

Never claim the AWS environment is live from repository code alone. Record account IDs, run IDs, plans, restore timestamps, and acceptance hashes in the controlled release evidence store.
