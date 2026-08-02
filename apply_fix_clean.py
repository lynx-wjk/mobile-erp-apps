import base64
import subprocess

sql = open(r"c:\Users\budic\Downloads\android\inventory_control_apps\fix_date_filters_v2.sql", "r", encoding="utf-8").read()
b64 = base64.b64encode(sql.encode('utf-8')).decode('utf-8')

# Call SSH directly to pipe base64 decoded string into docker exec psql
ssh_cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "root@38.47.191.226", f"echo '{b64}' | base64 -d | docker exec -i supabase-db psql -U postgres -d postgres"]

res = subprocess.run(ssh_cmd, capture_output=True, text=True)
print("STDOUT:", res.stdout)
print("STDERR:", res.stderr)
print("RETURN:", res.returncode)
