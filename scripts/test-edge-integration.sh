#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/apps/edge/wrangler.toml"
STATE="$(mktemp -d)"
PORT=8791
LOG="$STATE/wrangler.log"
cleanup() {
  if [[ -n "${WORKER_PID:-}" ]]; then kill "$WORKER_PID" 2>/dev/null || true; fi
  rm -rf "$STATE"
}
trap cleanup EXIT

cd "$ROOT"
npx wrangler d1 migrations apply challanse-pilot --local --persist-to "$STATE" --config "$CONFIG" >/dev/null
CODE="ABCDEFGH"
CODE_HASH="$(node -e "const c=require('node:crypto');process.stdout.write(c.createHash('sha256').update(process.argv[1]).digest('hex'))" "$CODE")"
SEED="INSERT INTO sites (id,name,allowed_wifi_ssids_json) VALUES ('site-1','Pilot Site','[\"SITE_WIFI\"]'); INSERT INTO vendors (id,site_id,name,initials,color,display_order) VALUES ('vendor-1','site-1','Pilot Vendor','PV','#f59e0b',0); INSERT INTO enrollment_codes (code_hash,site_id,device_name,expires_at,created_by) VALUES ('$CODE_HASH','site-1','Gate One',datetime('now','+10 minutes'),'admin@example.com');"
npx wrangler d1 execute challanse-pilot --local --persist-to "$STATE" --config "$CONFIG" --command "$SEED" >/dev/null

npx wrangler dev --local --persist-to "$STATE" --port "$PORT" --config "$CONFIG" --var DEVICE_TOKEN_PEPPER:test-pepper >"$LOG" 2>&1 &
WORKER_PID=$!
for _ in {1..30}; do curl --fail --silent "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 1; done
curl --fail --silent "http://127.0.0.1:$PORT/health" | grep -q '"ok"'

ENROLL="$(curl --fail --silent -X POST "http://127.0.0.1:$PORT/v1/devices/enroll" -H 'Content-Type: application/json' --data "{\"enrollmentCode\":\"$CODE\",\"deviceName\":\"Gate One\",\"appVersion\":\"1.0.0\"}")"
TOKEN="$(node -e "const p=JSON.parse(process.argv[1]);if(!p.deviceToken)process.exit(1);process.stdout.write(p.deviceToken)" "$ENROLL")"
curl --fail --silent "http://127.0.0.1:$PORT/v1/mobile/bootstrap" -H "Authorization: Bearer $TOKEN" | grep -q 'Pilot Vendor'

IMAGE="$STATE/receipt.webp"
printf 'RIFF\x04\x00\x00\x00WEBP' > "$IMAGE"
IMAGE_HASH="$(node -e "const fs=require('node:fs'),c=require('node:crypto');process.stdout.write(c.createHash('sha256').update(fs.readFileSync(process.argv[1])).digest('hex'))" "$IMAGE")"
RECEIPT_ID="0195279a-7f6f-4af8-bc14-28640f0aa99a"
METADATA="{\"receiptId\":\"$RECEIPT_ID\",\"vendorId\":\"vendor-1\",\"capturedAtUnix\":1800000000,\"capturedQuantity\":10,\"imageSha256\":\"$IMAGE_HASH\",\"appVersion\":\"1.0.0\",\"configurationVersion\":1}"
upload() {
  local nonce="$1"
  curl --silent -w '\n%{http_code}' -X POST "http://127.0.0.1:$PORT/v1/receipts" \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-ChallanSe-Nonce: $nonce" \
    -H "X-ChallanSe-Timestamp: $(date +%s)" \
    -F "metadata=$METADATA" -F "image=@$IMAGE;type=image/webp"
}
FIRST="$(upload nonce-0000000000000001)"
[[ "${FIRST##*$'\n'}" == "202" ]]
SECOND="$(upload nonce-0000000000000002)"
[[ "${SECOND##*$'\n'}" == "202" ]]
grep -q '"duplicate":true' <<<"$SECOND"
REPLAY="$(upload nonce-0000000000000002)"
[[ "${REPLAY##*$'\n'}" == "409" ]]
grep -q 'REPLAY_REJECTED' <<<"$REPLAY"

echo "Edge integration checks passed."
