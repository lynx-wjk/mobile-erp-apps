#!/usr/bin/env bash
set -euo pipefail

ACCOUNT_ID="6a6a6d63-fffb-431a-8812-191b9d87a84d"
ENV_FILE="/root/supabase-project/.env"
if [ ! -f "$ENV_FILE" ]; then
  ENV_FILE="/root/supabase-project/docker/.env"
fi

set -a
. "$ENV_FILE"
set +a

CRON_SECRET="${MARKETPLACE_CRON_SECRET:-${CRON_SECRET:-${MARKETPLACE_AUTO_RUNNER_SECRET:-}}}"

KONG_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' supabase-kong 2>/dev/null || true)
if [ -n "$KONG_IP" ]; then
  KONG_URL="http://$KONG_IP:8000"
else
  KONG_URL="http://127.0.0.1:8000"
fi

echo "Using KONG_URL=$KONG_URL"

dates=(
  "2026-07-01"
  "2026-07-02"
  "2026-07-03"
  "2026-07-04"
  "2026-07-05"
  "2026-07-06"
  "2026-07-07"
  "2026-07-08"
  "2026-07-09"
  "2026-07-10"
  "2026-07-11"
  "2026-07-12"
  "2026-07-13"
)

for dt in "${dates[@]}"; do
  echo "Pulling TikTok Shop finance statements for date: $dt"
  BODY=$(cat <<JSON
{
  "action": "pull_finance_statements_period",
  "account_id": "$ACCOUNT_ID",
  "start_date": "$dt",
  "end_date": "$dt",
  "include_sku_details": true,
  "max_statements": 100,
  "max_transactions": 100,
  "max_order_details": 100,
  "page_size": 50
}
JSON
)
  curl -sS --fail-with-body -X POST "$KONG_URL/functions/v1/marketplace-tiktok-service" \
    -H "Content-Type: application/json" \
    -H "x-marketplace-cron-secret: $CRON_SECRET" \
    --data "$BODY"
  echo "Completed date: $dt"
  sleep 2
done
