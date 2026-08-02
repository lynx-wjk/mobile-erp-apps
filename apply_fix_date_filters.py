import base64
import json
import subprocess

sql_content = open(r"c:\Users\budic\Downloads\android\inventory_control_apps\fix_date_filters.sql", "r", encoding="utf-8").read()
b64_sql = base64.b64encode(sql_content.encode("utf-8")).decode("utf-8")

cmd = f"echo '{b64_sql}' | base64 -d | docker exec -i supabase-db psql -U postgres -d postgres"

# We will run this via vps_ssh.runRemoteCommand
print(cmd)
