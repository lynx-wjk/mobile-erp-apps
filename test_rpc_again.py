import asyncio
import os
from supabase import create_client, Client

SUPABASE_URL = "http://127.0.0.1:54321"
SUPABASE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "") 
with open("supabase/.env", "r") as f:
    for line in f:
        if line.startswith("SERVICE_ROLE_KEY="):
            SUPABASE_KEY = line.strip().split("=")[1]
            break
        if line.startswith("SUPABASE_SERVICE_ROLE_KEY="):
            SUPABASE_KEY = line.strip().split("=")[1]
            break

supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

async def main():
    # Test for the missing order's date
    start_date = "2024-05-18" # roughly when it was created
    end_date = "2024-05-19"
    
    print("Testing finance_order_candidates_for_period_v3 with start_date={}, end_date={}".format(start_date, end_date))
    resp = supabase.rpc("finance_order_candidates_for_period_v3", {
        "p_start": start_date,
        "p_end": end_date,
        "p_marketplace": "tiktok_shop",
        "p_limit": 20,
        "p_missing_only": True,
    }).execute()
    
    orders = resp.data
    print("Found {} candidates:".format(len(orders)))
    for o in orders:
        print(o["order_id"])

if __name__ == "__main__":
    asyncio.run(main())
