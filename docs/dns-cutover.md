# DNS and production cutover

Do not change nameservers until this checklist is signed off by the domain owner.

## Inventory

1. Export every Namecheap record and capture screenshots of the current DNS and email configuration.
2. Recreate all `A`, `AAAA`, `CNAME`, `MX`, `TXT`, SPF, DKIM, DMARC, CAA, and ownership-verification records in Cloudflare without changing values or TTL intent.
3. Keep email-related records DNS-only. Do not proxy mail hosts.
4. Verify `www.constrovet.com`, apex redirects, and inbound/outbound email before nameserver cutover.

## ChallanSe records

1. Configure GitHub Pages custom domain `challanse.constrovet.com` and verify its domain challenge.
2. Deploy the API and reviewer Workers with their custom domains.
3. Protect the reviewer host and reviewer/admin API paths with Cloudflare Access.
4. Confirm valid HTTPS and no redirect loops on all three hosts.
5. Verify exact-origin CORS rejects every origin except the public and reviewer hosts.

## Controlled cutover

1. Set the GitHub production variables and secrets while `PILOT_DEPLOY_ENABLED=false`.
2. Run staging validation and obtain owner approval.
3. Change authoritative nameservers at Namecheap to the assigned Cloudflare nameservers.
4. Monitor DNS and email resolution from two independent networks.
5. Enable production deployment and approve the protected GitHub environment.
6. Update the main Constrovet navbar only after all three production readiness checks pass.
7. Replace the old ChallanSe page with a canonical client-side redirect only after the new URL is stable.

## Rollback

Disable `PILOT_DEPLOY_ENABLED`, restore the exported DNS records/nameservers, and leave the existing Constrovet route unchanged. Device records remain in the local queue until the approved API is restored.
