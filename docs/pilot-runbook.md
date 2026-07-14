# Controlled pilot runbook

## Scope

- One approved construction site.
- Maximum five enrolled Android devices.
- Two approved controller reviewers.
- Maximum 50 receipts per UTC day and 750 KB per synchronized image.
- Manual reviewer verification is authoritative.

## Readiness

1. Confirm production `/health` and `/ready` responses.
2. Confirm Cloudflare Access denies an unapproved email and permits both reviewers.
3. Seed only owner-approved vendors and Wi-Fi SSIDs.
4. Enroll two devices using separate single-use QR codes; prove expiry, reuse rejection, and revocation.
5. Confirm each device shows the correct site and vendor choices while offline.

## Field acceptance

1. Capture 100 receipts on an Android 8 / 2 GB profile and record p95 local database write time; acceptance requires below 50 ms and no metadata loss.
2. Complete a 20-receipt offline trial, restart the app, then reconnect while charging on permitted Wi-Fi.
3. Confirm each receipt appears exactly once and its SHA-256 checksum matches the private image.
4. Verify Site A cannot list or stream Site B data.
5. Verify concurrent reviewer edits return `409` and do not overwrite accepted data.
6. Confirm reviewer records challan number, material, quantity, unit, notes, identity, time, and immutable audit event.

## Operations

- At 70% storage allowance, the admin summary warns the controller.
- At 90%, cloud uploads pause; devices retain their local queue.
- Acknowledged device images remain for seven days before local removal.
- R2 images are deleted after 90 days; remaining receipt and audit data after one year.
- The scheduled reconciliation job recovers durable `RECEIVED` rows if queue delivery expires.
- Logs must never contain images, credentials, challan text, or personal contact fields.

## Incident response

Revoke a lost device immediately, preserve its unsynced local data if recoverable, and rotate the device-token pepper only as a coordinated re-enrollment event. Disable pilot deployment or uploads when authorization, data isolation, checksum validation, or retention controls fail.

## Pilot limits

Cloudflare and GitHub free tiers provide no uptime SLA or independent off-provider backup. Do not expand beyond the controlled scope until field acceptance, retention verification, and an approved paid resilience plan exist.
