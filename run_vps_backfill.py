import subprocess

def run_cmd(cmd):
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("Error:", res.stderr)
        return False
    print("Success:", res.stdout)
    return True

print("=== 1. SCP SCRIPT TO VPS ===")
scp_cmd = ['scp', 'vps_fast_payout_backfill.py', 'inventory-vps:/root/vps_fast_payout_backfill.py']
run_cmd(scp_cmd)

print("=== 2. RUN SCRIPT ON VPS ===")
ssh_cmd = ['ssh', 'inventory-vps', 'python3 /root/vps_fast_payout_backfill.py']
run_cmd(ssh_cmd)

