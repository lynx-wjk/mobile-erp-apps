import re
import urllib.parse

with open(r'c:\Users\budic\Downloads\android\inventory_control_apps\landing_page\index.html', 'r', encoding='utf-8') as f:
    content = f.read()

links = re.findall(r'href=["\'](https://wa\.me[^"\']+)["\']', content)
print('Total wa.me links in index.html:', len(links))
for i, l in enumerate(links, 1):
    parsed = urllib.parse.urlparse(l)
    query = urllib.parse.parse_qs(parsed.query)
    text = query.get('text', [''])[0]
    print(f'{i}. Full URL: {l}')
    print(f'   Phone/Path: {parsed.path}')
    print(f'   Decoded text: {repr(text)}')
