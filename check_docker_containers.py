import subprocess

def run_ssh(cmd_str):
    cmd = ['ssh', 'inventory-vps', cmd_str]
    res = subprocess.run(cmd, text=True, capture_output=True)
    if res.returncode != 0:
        print("SSH Error:", res.stderr)
        return ""
    return res.stdout.strip()

print("--- DOCKER PS ---")
print(run_ssh("docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"))

