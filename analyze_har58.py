import json
import os

har_path = r"C:\Users\budic\Downloads\mdhproduction.com debug58.har"

if not os.path.exists(har_path):
    print("File not found:", har_path)
    exit(1)

print(f"Loading HAR file: {har_path} (size: {os.path.getsize(har_path)} bytes)")

with open(har_path, 'r', encoding='utf-8', errors='ignore') as f:
    data = json.load(f)

entries = data.get('log', {}).get('entries', [])
print(f"Total entries in HAR: {len(entries)}")

requests_summary = []

for i, entry in enumerate(entries):
    req = entry.get('request', {})
    res = entry.get('response', {})
    url = req.get('url', '')
    method = req.get('method', '')
    status = res.get('status', 0)
    
    post_data = req.get('postData', {}).get('text', '')
    res_text = res.get('content', {}).get('text', '')

    if 'rpc' in url or 'rest/v1' in url or 'functions/v1' in url:
        print(f"\n--- Entry #{i+1}: {method} {url} (Status: {status}) ---")
        if post_data:
            print("Request Body:", post_data[:500])
        if res_text:
            print("Response Body (first 500 chars):", res_text[:500])
            
            # Save response to a file for deep analysis if needed
            if 'rpc' in url:
                rpc_name = url.split('/rpc/')[-1].split('?')[0]
                print(f"RPC Name: {rpc_name}")

