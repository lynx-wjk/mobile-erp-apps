import subprocess

def run_cmd(cmd):
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("Error:", res.stderr)
        return False
    print("Success:", res.stdout)
    return True

print("=== DEPLOYING UPDATED MARKETPLACE-TIKTOK-SERVICE TO VPS ===")
scp_cmd = ['scp', 'supabase/functions/marketplace-tiktok-service/index.ts', 'inventory-vps:/root/mobile-erp-apps/supabase/functions/marketplace-tiktok-service/index.ts']
run_cmd(scp_cmd)

ssh_cmd = ['ssh', 'inventory-vps', 'docker restart supabase-edge-functions']
run_cmd(ssh_cmd)

