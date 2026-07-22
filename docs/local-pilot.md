# ChallanSe Local Pilot

This environment defaults to supervised demonstrations with synthetic data. A guarded `controlled-client-pilot` mode exists, but remains unavailable until individual reviewer MFA, a recent encrypted backup, a tested restore, an independent security report, and signed client approval are recorded. AWS deployment remains frozen. Images, OCR text, PostgreSQL data, and exports stay in the encrypted pilot container. Cloudflare Tunnel, when explicitly started, transports encrypted traffic but does not store receipt payloads.

For a command-by-command synthetic test procedure with expected outputs, use [`local-testing-runbook.md`](local-testing-runbook.md).

On Snap-packaged Docker, the CLI automatically applies `deploy/local/docker-compose.snap.yml`. Snap's runtime rejects all container execution when `no-new-privileges` is requested, so the override removes only that incompatible option after verifying Docker still reports AppArmor and built-in seccomp. Read-only roots, dropped capabilities, non-root users, resource limits, pinned images, and isolated networks remain enforced.

## Safety Boundary

- Never use real challans, vendors, people, GST numbers, bank details, or Tally exports while the status reports `synthetic-demo`.
- `/dev/sda2` contains existing personal and local-LLM files and must never be formatted by ChallanSe.
- `storage-prepare` creates a separate 20 GB LUKS2 container file and preserves every existing host-partition file.
- LAN startup requires UFW rules restricted to the detected local subnet.
- Remote startup is optional and requires a dedicated Cloudflare Tunnel plus Access application allowing only `admin@constrovet.com` and `bhagat.taran@gmail.com`.
- The PC must remain on during a demonstration. Mobile receipts remain queued when it is off.

## First Setup

Run one command at a time:

```bash
cd /home/taran/challanse-website
./scripts/local-pilot.sh preflight
./scripts/local-pilot.sh storage-audit
```

Preflight requires Android SDK 36, Build Tools `36.0.0`, and NDK `27.1.12297006` so the sideloadable synthetic APK can be built locally. It stops with a clear error and creates nothing when these components are absent.

Stop and inspect the storage audit. Install `cryptsetup` once, then create the separate encrypted container:

```bash
sudo apt update
sudo apt install -y cryptsetup
./scripts/local-pilot.sh storage-prepare
./scripts/local-pilot.sh firewall-prepare
./scripts/local-pilot.sh provision
```

For `storage-prepare`, type `CREATE-20GB-ENCRYPTED-CHALLANSE-CONTAINER` and create a strong LUKS passphrase. The command safely reuses the desktop's existing `/dev/sda2` mount when present, exposes it through `/mnt/challanse-host`, and allocates `/mnt/challanse-host/challanse-local.luks`. It does not format `/dev/sda2`. After a reboot, reopen it before starting the pilot:

```bash
./scripts/local-pilot.sh storage-open
```

If passphrase confirmation fails during the first format, rerun `storage-prepare`. The CLI validates the exact file, confirms it is not LUKS, checks its size, owner, mode, and link count, then requests `RECOVER-INCOMPLETE-CHALLANSE-CONTAINER` before removing only that incomplete file.

Reviewer credentials are not created during provisioning. Each named reviewer receives an Argon2id password, TOTP MFA secret, and one-time recovery codes through the guarded enrollment command. Install `~/.config/challanse-local/tls/pilot-ca.crt` as a trusted certificate only on supervised reviewer devices. The Android local-pilot APK contains only that public pilot CA certificate.

## Start a LAN Demonstration

```bash
./scripts/local-pilot.sh start --lan
./scripts/local-pilot.sh seed
./scripts/local-pilot.sh test-data
./scripts/local-pilot.sh reviewer-enroll
./scripts/local-pilot.sh reviewer-enroll
./scripts/local-pilot.sh status
./scripts/local-pilot.sh download-apk
```

Install `artifacts/local-pilot/ChallanSe-Local-Pilot.apk` on the test Android device. Then generate a ten-minute enrollment link:

```bash
./scripts/local-pilot.sh enroll
```

Open the link on the Android device. The app name and persistent banner both identify the build as synthetic.

Store each TOTP URI and recovery-code set separately and offline. They are shown once. Every login, correction, export, and administrative operation is then associated with an individual reviewer session; mutating browser requests also require a session-bound CSRF token.

## Independent Backup

Real-data activation requires a separately mounted encrypted USB drive. The CLI rejects internal disks. Connect the approved drive, then run:

```bash
./scripts/local-pilot.sh backup /media/USER/CLIENT-BACKUP
./scripts/local-pilot.sh backup-verify /media/USER/CLIENT-BACKUP
```

The first command writes an encrypted Restic snapshot. The second verifies repository data, restores the latest snapshot into temporary encrypted storage, confirms that the database dump is present, writes evidence, and removes the temporary restored copy. Disconnect the USB drive afterward. Activation requires a successful backup from the previous 24 hours and a restore verification from the previous 30 days.

## Controlled Client Activation

Do not activate this mode without a qualified independent security review and signed client agreement. Prepare a private JSON file containing one organization, one site, exactly two named reviewers, approved Wi-Fi SSIDs, and approved vendors. Keep it outside Git.

```bash
./scripts/local-pilot.sh prepare-client /secure/client-pilot.json
./scripts/local-pilot.sh reviewer-enroll
./scripts/local-pilot.sh reviewer-enroll
./scripts/local-pilot.sh backup /media/USER/CLIENT-BACKUP
./scripts/local-pilot.sh backup-verify /media/USER/CLIENT-BACKUP
./scripts/local-pilot.sh activate-client-pilot \
  /secure/signed-client-approval.pdf \
  /secure/independent-security-review.pdf \
  /mnt/challanse-data/exports/backup-restore-SNAPSHOT.json
```

The command hashes the three evidence files and activates the database-controlled mode only when all gates pass. Editing an environment file cannot activate real-data mode. To end capture and later remove client data after the agreed retention period:

```bash
./scripts/local-pilot.sh end-client-pilot
./scripts/local-pilot.sh purge-ended-client-pilot
```

The purge command fails until the configured retention period has expired.

## Optional Remote Demonstration

In Cloudflare Zero Trust, create a dedicated pilot tunnel and two public hostnames:

- `api-pilot.challanse.constrovet.com` to `http://edge:8787`
- `review-pilot.challanse.constrovet.com` to `http://reviewer-worker:8788`

Protect the reviewer hostname with Cloudflare Access and allow only the two approved reviewer emails. Do not protect the mobile API hostname with browser login; mobile authentication uses revocable device tokens and request nonces. Then run:

```bash
./scripts/local-pilot.sh start --both
```

The CLI requests the tunnel token, Access team domain, and Access audience without printing them. Remote access exists only while the supervised tunnel container is running.

## Acceptance and Evidence

```bash
./scripts/local-pilot.sh acceptance
./scripts/local-pilot.sh evidence
./scripts/quality-loop.sh observe
```

The acceptance command uploads 50 generated WebP receipts through resumable upload contracts, verifies durable acknowledgements, and waits up to 30 minutes for the sequential OCR queue to drain. It does not replace the required Android 8 / 2 GB device write test.

Evidence is written under `/mnt/challanse-data/exports`. The encrypted host mount is exposed inside backend containers as `/srv/challanse`. Evidence includes the commit, container identities, model list, OCR versions, APK checksum, standards mapping, test status, and explicit limitations. It does not contain passwords, device tokens, CA private keys, or tunnel credentials. `quality-loop.sh improve` may create an isolated branch and pull request, but it cannot merge, release, activate client mode, rotate credentials, delete data, or change network routes.

## Stop or Reset

```bash
./scripts/local-pilot.sh stop
./scripts/local-pilot.sh storage-close
```

Stopping and closing preserve PostgreSQL, images, fixtures, mobile queues, and all pre-existing `/dev/sda2` files. To recreate only server-side synthetic records:

```bash
./scripts/local-pilot.sh reset
```

To delete all local synthetic server data and secrets while preserving the encrypted disk itself:

```bash
./scripts/local-pilot.sh destroy
```

## Honest Limitations

- This validates workflow and usability, not production resilience or real OCR accuracy.
- OCR normalization can be slow on CPU and runs one receipt at a time.
- Low-confidence, unavailable, invalid, or untraceable model output requires human review.
- Controlled client mode requires an encrypted off-device backup and successful restore evidence; without them the system remains synthetic-only.
- Independent security review, real-device performance evidence, a two-device field trial, UPS readiness, and signed client acceptance are human gates and are not satisfied by source-code tests.
- No statutory, GST, credit, notification, or financial-production integration is enabled.
