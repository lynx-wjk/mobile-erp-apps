import subprocess
import json
import requests
import time
import hmac
import hashlib

def run_sql(sql):
    cmd = ['ssh', 'inventory-vps', f'docker exec -i supabase-db psql -U postgres -d postgres -t -A -c "{sql}"']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SQL Error:", res.stderr)
        return ""
    return res.stdout.strip()

# Retrieve account token and secrets
sql_acc = """
SELECT marketplace_account_id, access_token, refresh_token, credentials_json, raw_account
FROM marketplace_accounts
WHERE marketplace_account_id = '6a6a6d63-fffb-431a-8812-191b9d87a84d';
"""
acc_raw = run_sql(sql_acc)
print("Account info fetched.")

# Also get TikTok app credentials from runtime secret or config
sql_app_key = "SELECT app_private.get_runtime_secret('tiktok_app_key');"
sql_app_secret = "SELECT app_private.get_runtime_secret('tiktok_app_secret');"
app_key = run_sql(sql_app_key)
app_secret = run_sql(sql_app_secret)
print("App Key present:", bool(app_key), "App Secret present:", bool(app_secret))

