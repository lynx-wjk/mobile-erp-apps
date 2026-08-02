#!/usr/bin/env bash
set -uo pipefail

TENANT_ID="ae730499-550b-4907-bb18-bbc2629c64f4"

ACCOUNT_ID=$(docker exec -i supabase-db psql -U postgres -d postgres -At <<SQL
select marketplace_account_id
from public.marketplace_accounts
where tenant_id = '$TENANT_ID'
  and marketplace = 'tiktok_shop'
  and status = 'active'
order by updated_at desc
limit 1;
SQL
)

echo "ACCOUNT_ID=$ACCOUNT_ID"

ENV_FILE="/root/supabase-project/.env"
if [ ! -f "$ENV_FILE" ]; then
  ENV_FILE="/root/supabase-project/docker/.env"
fi

set -a
. "$ENV_FILE"
set +a

CRON_SECRET="${MARKETPLACE_CRON_SECRET:-${CRON_SECRET:-${MARKETPLACE_AUTO_RUNNER_SECRET:-}}}"

KONG_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' supabase-kong 2>/dev/null || true)
KONG_URL="http://$KONG_IP:8000"

echo "KONG_URL=$KONG_URL"

echo "DELETE old test rows..."
docker exec -i supabase-db psql -U postgres -d postgres <<SQL
delete from public.marketplace_finance_items
where tenant_id = '$TENANT_ID'
  and marketplace = 'tiktok_shop'
  and order_sn in (
    '584655970334050053',
    '584658003593626909',
    '584658222608647313'
  );

select count(*) as remaining_test_rows
from public.marketplace_finance_items
where tenant_id = '$TENANT_ID'
  and marketplace = 'tiktok_shop'
  and order_sn in (
    '584655970334050053',
    '584658003593626909',
    '584658222608647313'
  );
SQL

BODY=$(cat <<JSON
{
  "action": "pull_finance_statements_period",
  "account_id": "$ACCOUNT_ID",
  "start_date": "2026-06-23",
  "end_date": "2026-06-23",
  "include_sku_details": false,
  "max_statements": 1,
  "max_transactions": 20,
  "max_order_details": 0,
  "page_size": 20
}
JSON
)

echo "INVOKE lightweight fallback mode..."
curl -sS -X POST "$KONG_URL/functions/v1/marketplace-tiktok-service" \
  -H "Content-Type: application/json" \
  -H "x-marketplace-cron-secret: $CRON_SECRET" \
  --data "$BODY"

echo
echo "VALIDATE rows..."
docker exec -i supabase-db psql -U postgres -d postgres <<SQL
select
  order_sn,
  statement_id,
  statement_transaction_id,
  marketplace_sku,
  marketplace_seller_sku,
  marketplace_product_name,
  marketplace_variation_name,
  qty,
  gross_amount,
  received_amount,
  net_settlement,
  platform_fee,
  commission_fee,
  affiliate_fee,
  shipping_fee,
  discount_amount,
  refund_amount,
  raw_item->>'_finance_order_item_fallback' as fallback_item,
  raw_item->>'_finance_allocation_ratio' as allocation_ratio
from public.marketplace_finance_items
where tenant_id = '$TENANT_ID'
  and marketplace = 'tiktok_shop'
  and order_sn in (
    '584655970334050053',
    '584658003593626909',
    '584658222608647313'
  )
order by order_sn, marketplace_sku, marketplace_variation_name;
SQL