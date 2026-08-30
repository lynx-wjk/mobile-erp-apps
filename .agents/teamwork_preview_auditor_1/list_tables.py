import re

with open(r'c:\Users\budic\Downloads\android\inventory_control_apps\migration_selfhost\schema.sql', 'r', encoding='utf-8', errors='ignore') as f:
    sql = f.read()

# Pattern for pg_dump style: CREATE TABLE "public"."table_name" or CREATE TABLE public.table_name
tables = re.findall(r'CREATE TABLE (?:IF NOT EXISTS )?(?:"?public"?\.)?"?([a-zA-Z0-9_]+)"?', sql, re.IGNORECASE)
unique_tables = sorted(set(tables))
print(f'Total tables found: {len(unique_tables)}')
for t in unique_tables:
    if t not in ('AS', 'IF'):
        print('  -', t)
