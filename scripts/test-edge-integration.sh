#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if rg -n '^\[\[(d1_databases|r2_buckets|queues)\]\]' apps/edge/wrangler.toml; then
  echo "The production API Worker must not bind application storage or queues." >&2
  exit 1
fi

if rg -n 'env\.(DB|RECEIPTS|RECEIPT_QUEUE)' apps/edge/src; then
  echo "The production API Worker must remain stateless." >&2
  exit 1
fi

npm run check --workspace @challanse/edge
npm test --workspace @challanse/edge
npm run build --workspace @challanse/edge

echo "Stateless edge routing checks passed."
