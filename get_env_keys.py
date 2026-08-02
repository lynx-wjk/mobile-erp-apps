import subprocess

def run_vps(cmd_str):
    cmd = ['ssh', 'inventory-vps', cmd_str]
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("VPS Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- FIND ENV FILES ON VPS ---")
print(run_vps("find /root /opt -name '.env*' 2>/dev/null"))

print("\n--- CHECK DOCKER ENV OF SUPABASE-EDGE-FUNCTIONS ---")
print(run_vps("docker exec -i supabase-edge-functions env | grep -i key"))

