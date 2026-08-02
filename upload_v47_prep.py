import base64
import os
import json
import subprocess
from mcp import ClientSession

def run():
    b64_file = r"c:\Users\budic\Downloads\android\inventory_control_apps\web_v47.b64"
    with open(b64_file, "r") as f:
        data = f.read()

    chunk_size = 500000 # 500KB per chunk
    chunks = [data[i:i+chunk_size] for i in range(0, len(data), chunk_size)]
    print(f"Total base64 length: {len(data)}, total chunks: {len(chunks)}")

    # Clear remote temp file
    cmd1 = 'docker exec mobile-erp-web rm -f /tmp/v47.b64 /tmp/v47.tar.gz'
    # we use runRemoteCommand via vps_ssh tool or powershell script
    # let's prepare powershell script to execute remote commands sequentially
    print("Uploading base64 chunks to VPS...")

if __name__ == "__main__":
    run()
