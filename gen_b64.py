import base64

sql = open(r"c:\Users\budic\Downloads\android\inventory_control_apps\fix_hpp_hardcoded_v6.sql", "r", encoding="utf-8").read()
b64 = base64.b64encode(sql.encode('utf-8')).decode('utf-8')
with open(r"c:\Users\budic\Downloads\android\inventory_control_apps\fix_b64.txt", "w", encoding="utf-8") as f:
    f.write(b64)
print(f"Encoded {len(sql)} bytes SQL -> {len(b64)} bytes base64")
