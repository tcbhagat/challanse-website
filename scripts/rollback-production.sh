#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="tcbhagat/challanse"
cd "$ROOT"

gh variable set PILOT_DEPLOY_ENABLED --repo "$REPO" --body false
printf 'New production deployments are disabled. Existing PostgreSQL, S3, SQS, and device data were preserved.\n'

if [[ "${1:-}" == "--revoke-devices" ]]; then
  printf '%s\n' 'Device revocation is tenant-scoped in the authenticated administrator console. Global database revocation is intentionally not performed by this local rollback script.' >&2
  exit 2
fi
