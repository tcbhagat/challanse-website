# Beginner-safe Cloudflare activation

This migration changes only the authoritative DNS provider. It must preserve the existing website, application, and Google Workspace email.

## Before starting

Confirm all three services work and write down what you observed:

1. Open `https://www.constrovet.com`.
2. Open `https://app.constrovet.com`.
3. Send an external email to an active `@constrovet.com` mailbox.
4. Reply from that mailbox and confirm delivery.

Keep the supplied Namecheap screenshot. Do not continue if any service is already failing.

## Prepare Cloudflare safely

Run:

```bash
cd /home/taran/challanse-website
git pull --ff-only
./scripts/go-live.sh dns-onboard
```

The command prompts for a Cloudflare API token and account ID, creates or reuses the `constrovet.com` Free-plan zone, and checks these records exactly:

| Type | Host | Value | Priority | Status |
| --- | --- | --- | --- | --- |
| A | `app` | `34.102.192.38` | — | DNS only |
| CNAME | `www` | `tcbhagat.github.io` | — | DNS only |
| MX | `@` | `ALT4.ASPMX.L.GOOGLE.COM` | `10` | DNS only |

It aborts instead of overwriting a conflicting record. It does not create ChallanSe records, change Namecheap, or store the Cloudflare token.

The token needs Zone Read and DNS Edit for `constrovet.com`, plus Zone Edit if the zone has not yet been added. Select only the Constrovet account and domain when creating it.

## Change Namecheap nameservers

The CLI prints two Cloudflare nameservers. Copy them exactly.

1. Sign in to Namecheap and open **Domain List**.
2. Click **Manage** beside `constrovet.com`.
3. Open the **Domain** tab, not **Advanced DNS**.
4. Find **Nameservers**.
5. Change **Namecheap BasicDNS** to **Custom DNS**.
6. Paste the first Cloudflare nameserver.
7. Add the second row and paste the second nameserver.
8. Click the green checkmark.
9. Leave DNSSEC off.
10. Do not delete the old Namecheap Advanced DNS records; they are the rollback reference.

## Wait and verify

Every 15–30 minutes run:

```bash
./scripts/go-live.sh dns-status
```

This checks Cloudflare nameservers, the exact `app`, `www`, and MX values, and HTTPS for both public services. Activation can take up to 24 hours.

After the command passes, manually test inbound and outbound email again. Then record acceptance:

```bash
./scripts/go-live.sh dns-accept
```

The command requires explicit confirmation for the website, application, and both email directions. No email contents or credentials are stored.

## If anything fails

Immediately return to Namecheap **Domain List → Manage → Domain → Nameservers**, select **Namecheap BasicDNS**, and click the green checkmark. Do not delete Cloudflare or Namecheap records while diagnosing.

## Continue ChallanSe

Only after `dns-accept` succeeds:

```bash
./scripts/go-live.sh preflight
./scripts/go-live.sh provision
./scripts/go-live.sh configure-github
./scripts/go-live.sh deploy
```

The production preflight refuses to continue without the local DNS acceptance marker and an active Cloudflare zone.

References: [Cloudflare full-zone setup](https://developers.cloudflare.com/dns/zone-setups/full-setup/setup/), [Namecheap nameserver instructions](https://www.namecheap.com/support/knowledgebase/article.aspx/767/10/how-to-change-dns-for-a-domain/), and [Google Workspace MX guidance](https://support.google.com/a/answer/9222085).
