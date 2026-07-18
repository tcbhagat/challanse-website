# ChallanSe three-month pilot budget

## Approval envelope

The controlled first-client pilot has an internal cash ceiling of **INR 450,000**. Founder implementation and support time is treated as a non-cash contribution of approximately 220–300 hours. Existing Android and reviewer devices are used; replacement hardware is not included.

| Category | Approved planning amount |
| --- | ---: |
| Three months AWS and supporting services | INR 180,000 |
| Independent security assessment | INR 100,000–200,000 |
| Legal, privacy, and pilot documentation | INR 30,000–75,000 |
| Play Console, Workspace, and field expenses | INR 15,000–30,000 |
| Expected range | INR 325,000–485,000 |
| Hard approval ceiling | INR 450,000 |

The ceiling is an internal cost budget, not a client quotation. Security and legal allowances require at least two written quotations before purchase. Tax treatment and input-credit eligibility require accountant confirmation.

## Monthly cloud controls

The combined AWS operating ceiling is **INR 60,000 per month**, including an 18% tax allowance and 10% foreign-exchange/usage contingency. At the planning exchange rate of INR 96.22 per USD, configure these environment budgets:

| Account | Monthly AWS budget | Purpose |
| --- | ---: | --- |
| Production | USD 350 | Multi-AZ RDS, two NAT gateways, API/workers/tunnel, ALB, storage, logs, backups, queues, KMS, OCR |
| Staging | USD 225 | Single-AZ RDS, NAT gateway, API/worker/tunnel, ALB, test storage and logs |
| Recovery | USD 50 | Cross-account backup vault and restore evidence |
| Combined | USD 625 | Approximately INR 60,138 before card/bank variation |

AWS Budgets must notify two operators at 50%, 70%, 90%, and 100%. The 50% and 70% alerts are forecast warnings; 90% and 100% are actual-spend escalation points. Production deployment is blocked when either operator email or either environment budget is missing.

## Spending gates

1. Initial authorization is limited to INR 25,000 for account verification, tooling, and professional quotations.
2. Persistent AWS resources are prohibited until the signing fix is merged, the exposed signing identity is rotated, account ownership is verified, and budget alerts are configured.
3. The first AWS month requires reviewed staging and production Terraform plans within their environment ceilings.
4. Real client data is prohibited until legal/privacy and independent security reviews are complete.
5. Stop and obtain written reapproval when forecast AWS spend exceeds INR 60,000 monthly or total pilot cash spend exceeds INR 450,000.
6. Review forecast versus actual weekly during implementation and monthly during the pilot.
7. Purchase no Reserved Instances or Savings Plans during the three-month pilot.

## Cost allocation and evidence

All Terraform-managed resources carry `Project`, `Environment`, `Owner`, `CostCenter`, `ClientScope`, `ManagedBy`, and `DataClass` tags. Shared pilot infrastructure uses `ClientScope=shared-pilot`; client-specific usage is attributed through organization/site application metadata.

Retain the following evidence outside the repository and record its SHA-256 where the release process requires it:

- reviewed Terraform plans and monthly estimates;
- AWS Budget definitions and notification confirmations for two operators;
- weekly and monthly forecast-versus-actual reports;
- Play Console and Workspace invoices;
- security and legal quotations, purchase approvals, and final reports;
- any approved budget exception with owner, amount, reason, and expiry.

## Assumptions

- One controlled client, two reviewers, no more than five devices, and approximately 50 receipts daily.
- Three months begin at production activation, not development start.
- Cloudflare Free and the existing GitHub plan remain sufficient.
- Textract uses `DetectDocumentText`; forms/tables analysis requires separate budget approval.
- GST, credit, WhatsApp, Slack, and individual notifications remain disabled and unfunded.
- Provider pricing and exchange rates must be refreshed before the first Terraform apply.
