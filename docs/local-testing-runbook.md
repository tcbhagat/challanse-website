# ChallanSe Local Synthetic Testing Runbook

Use this runbook only with synthetic data. Do not activate controlled-client mode.

## Verified Baseline

- Repository: `/home/taran/challanse-website`
- Encrypted data mount: `/mnt/challanse-data`
- API: `https://192.168.1.7:8443`
- Reviewer: `https://192.168.1.7:8444`
- Local-pilot APK SHA-256 at commit `6cbd3f0`:
  `80b155d66e73c530b7f2e2d7bd324e1275fba71afe85d81ad87b6c53dafb0daf`

If the LAN address changes, stop the stack and run `./scripts/local-pilot.sh refresh-lan` before continuing.

## 1. Open Storage and Start Services

After every reboot, run one command at a time:

```bash
cd /home/taran/challanse-website
sudo -v
./scripts/local-pilot.sh storage-open
findmnt --mountpoint /mnt/challanse-data
./scripts/local-pilot.sh start --lan
./scripts/local-pilot.sh status
```

If storage is already open, `storage-open` reports that the encrypted container is open and preserves existing data.

Expected mount source:

```text
/mnt/challanse-data /dev/mapper/challanse-local ext4
```

Expected startup summary:

```text
GREEN: ChallanSe synthetic pilot is ready on LAN.
Reviewer: https://192.168.1.7:8444
```

Status must report:

```text
pilotMode: synthetic-demo
database: ready
objectStore: ready
ollama: ready
tesseract: ready
queueDepth: 0
terminalFailures: 0
GREEN: synthetic-demo services and integrity gates are ready.
```

`activation.ready: false` and backup status `MISSING` are expected for synthetic testing.

## 2. Generate and Validate Test Data

```bash
./scripts/local-pilot.sh test-data
ls -lh /mnt/challanse-data/fixtures
column -s, -t /mnt/challanse-data/fixtures/synthetic-tally.csv
jq . /mnt/challanse-data/fixtures/manifest.json
```

Expected files:

```text
01-english-clear.webp
02-hindi-english.webp
03-quantity-decimal.webp
04-low-contrast.webp
05-rotated.webp
manifest.json
synthetic-tally.csv
```

Expected Tally input:

```text
po_number  material_code   quantity  unit
PO-SYN-001 CEMENT-OPC      100       BAG
PO-SYN-002 STEEL-TMT       500       KG
PO-SYN-003 SAND-M          20        TON
PO-SYN-004 BRICK-FLYASH    2000      NOS
```

The importer normalizes `TON` to `MT`. The five images cover clear English, Hindi-English, decimal quantity, low contrast, and rotation. Low-contrast or rotated images may correctly require human review.

## 3. Run Automated Acceptance

```bash
./scripts/local-pilot.sh acceptance
```

The CPU-only OCR queue runs sequentially. Allow up to 30 minutes and do not start a second acceptance run.

Required report fields:

```json
{
  "synthetic": true,
  "receiptCount": 50,
  "uniqueReceiptCount": 50,
  "allAcknowledgedBeforeOcrDrain": true,
  "queueDepthAfterWait": 0,
  "passed": true
}
```

Generate evidence only after acceptance passes:

```bash
./scripts/local-pilot.sh evidence
LATEST=$(find /mnt/challanse-data/exports -maxdepth 1 -type d -name 'evidence-*' | sort | tail -1)
jq . "$LATEST/acceptance-report.json"
cat "$LATEST/limitations.txt"
```

Expected:

```text
Evidence pack created: /mnt/challanse-data/exports/evidence-YYYYMMDDTHHMMSSZ
```

Use only a pack containing an `acceptance-report.json` with `passed: true` and no `INVALID-*` marker.

## 4. Test Reviewer Login and Reconciliation

Verify the protected login redirect:

```bash
curl --cacert ~/.config/challanse-local/tls/pilot-ca.crt \
  -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  https://192.168.1.7:8444/
```

Expected:

```text
303 https://192.168.1.7:8444/login
```

Install `~/.config/challanse-local/tls/pilot-ca.crt` only on supervised reviewer devices. Open `https://192.168.1.7:8444`, then sign in with one reviewer's individual password and TOTP.

Validate:

1. Correct password plus TOTP opens the inbox.
2. Wrong password or TOTP is rejected.
3. Private images are unavailable without a valid reviewer session.
4. OCR text, confidence, and correction controls appear with the image.
5. Verify records reviewer identity and before/after values.
6. A stale concurrent edit returns `409` and does not overwrite the first edit.
7. Logout invalidates the session.

Upload `/mnt/challanse-data/fixtures/synthetic-tally.csv`. Four rows must import; a second upload must be reported as a duplicate. Verify `25 BAG` against `PO-SYN-001` to confirm no red delta. For a deliberate synthetic anomaly, verify `110 BAG` against the same 100-BAG PO; the row must turn red.

## 5. Test Android Capture and Offline Sync

```bash
./scripts/local-pilot.sh download-apk
sha256sum artifacts/local-pilot/ChallanSe-Local-Pilot.apk
adb devices
adb install -r artifacts/local-pilot/ChallanSe-Local-Pilot.apk
```

Expected install result:

```text
Success
```

Generate a ten-minute, single-use enrollment link:

```bash
./scripts/local-pilot.sh enroll
```

Expected:

```text
Enrollment expires in 10 minutes.
Open this link on the pilot device:
challanse-local://enroll?...
```

Never share or save the complete enrollment link in chat or source control.

On Android:

1. Confirm the app banner says `SYNTHETIC TEST`.
2. Confirm four synthetic vendors appear.
3. Display or print each WebP fixture and capture it through the camera.
4. Disable Wi-Fi, capture three receipts, and verify immediate haptic save.
5. Restart the app and confirm queued receipts remain.
6. Keep the device charging.
7. Connect to Wi-Fi or a hotspot named exactly `SYNTHETIC-SITE-WIFI`.
8. Confirm queued receipts synchronize and appear in the reviewer inbox without duplicates.
9. Revoke the device and confirm later uploads are rejected.

This test does not replace the required Android 8, 2 GB, 100-write performance measurement.

## 6. Stop Safely

```bash
./scripts/local-pilot.sh stop
./scripts/local-pilot.sh storage-close
```

Expected:

```text
Local services stopped. Mobile queues and synthetic data were preserved.
Encrypted ChallanSe container is closed. Existing host files remain mounted and unchanged.
```

Do not run `reset`, `destroy`, `prepare-client`, or `activate-client-pilot` during ordinary synthetic testing.
