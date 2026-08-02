import base64
import json

sql = open(r"c:\Users\budic\Downloads\android\inventory_control_apps\fix_date_filters_v2.sql", "r", encoding="utf-8").read()
b64 = base64.b64encode(sql.encode('utf-8')).decode('utf-8')

# Run remote command using docker exec
cmd = f"echo '{b64}' | base64 -d | docker exec -i supabase-db psql -U postgres -d postgres"
print(cmd)
