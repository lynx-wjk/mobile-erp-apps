import subprocess
import os

def scp_file(local_path, remote_path):
    cmd = ['scp', local_path, f'inventory-vps:{remote_path}']
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print(f"SCP Error ({local_path} -> {remote_path}):", res.stderr)
        return False
    print(f"Uploaded {local_path} -> {remote_path}")
    return True

base_local = r'C:\Users\budic\Downloads\android\inventory_control_apps\supabase\functions'
remote_dirs = [
    '/opt/supabase/volumes/functions',
    '/root/mobile-erp-apps/supabase/functions',
    '/root/supabase-project/volumes/functions'
]

for remote_dir in remote_dirs:
    scp_file(os.path.join(base_local, 'marketplace-tiktok-service', 'index.ts'), f'{remote_dir}/marketplace-tiktok-service/index.ts')
    scp_file(os.path.join(base_local, 'marketplace-order-pull', 'index.ts'), f'{remote_dir}/marketplace-order-pull/index.ts')
    scp_file(os.path.join(base_local, 'marketplace-auto-runner', 'index.ts'), f'{remote_dir}/marketplace-auto-runner/index.ts')
    scp_file(os.path.join(base_local, 'marketplace-finance-dispatcher', 'index.ts'), f'{remote_dir}/marketplace-finance-dispatcher/index.ts')
    scp_file(os.path.join(base_local, 'marketplace-finance-pull', 'index.ts'), f'{remote_dir}/marketplace-finance-pull/index.ts')

res = subprocess.run(['ssh', 'inventory-vps', 'docker restart supabase-edge-functions'], text=True, capture_output=True)
print("Restart edge functions container:", res.stdout.strip())
