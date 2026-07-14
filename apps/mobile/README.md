# ChallanSe Android capture

Android 8+ offline-first receipt capture for enrolled pilot devices.

- A single-use 10-minute QR exchanges for a revocable device token.
- The token and local database key are held in Android Keystore-backed Keychain storage.
- Real site vendors and approved Wi-Fi SSIDs download at enrollment and remain cached offline.
- Capture persists UUID, site, device, vendor, quantity, timestamp, app/config versions, and image before confirming success.
- Background synchronization runs only while charging on approved Wi-Fi, uploads WebP at no more than 750 KB, and retains unsynced records.
- Acknowledged image payloads remain locally for a seven-day recovery window.

The Jest 100-write guard verifies metadata completeness and detects JavaScript-path regressions. It is not a substitute for the required Android 8 / 2 GB physical-device p95 acceptance test in `docs/pilot-runbook.md`.
