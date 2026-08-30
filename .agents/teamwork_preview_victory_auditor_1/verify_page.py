import os, sys, json, re, urllib.parse
from html.parser import HTMLParser

class SimpleHTMLParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.images = []
        self.meta_tags = []
        self.link_tags = []
        self.scripts = []
        self.current_script = None

    def handle_starttag(self, tag, attrs):
        attr_dict = dict(attrs)
        if tag == 'a':
            self.links.append(attr_dict)
        elif tag == 'img':
            self.images.append(attr_dict)
        elif tag == 'meta':
            self.meta_tags.append(attr_dict)
        elif tag == 'link':
            self.link_tags.append(attr_dict)
        elif tag == 'script':
            if attr_dict.get('type') == 'application/ld+json':
                self.current_script = {'type': attr_dict.get('type'), 'content': ''}

    def handle_endtag(self, tag):
        if tag == 'script' and self.current_script is not None:
            self.scripts.append(self.current_script)
            self.current_script = None

    def handle_data(self, data):
        if self.current_script is not None:
            self.current_script['content'] += data

def main():
    index_path = 'landing_page/index.html'
    with open(index_path, 'r', encoding='utf-8') as f:
        html = f.read()

    parser = SimpleHTMLParser()
    parser.feed(html)

    print('=== 1. ENTERPRISE TERMS CHECK ===')
    terms = [
        'Tim Konsultan Enterprise',
        'Tim Solusi Mobile ERP',
        'Hubungi Tim Spesialis',
        'Jadwalkan Demo Sistem'
    ]
    for t in terms:
        count = html.count(t)
        print(f'Term "{t}": {count} occurrences')

    print('\n=== 2. WHATSAPP & CONTACT CHECK ===')
    wa_links = [l for l in parser.links if 'wa.me' in l.get('href', '') or 'whatsapp' in l.get('href', '')]
    print(f'Total WhatsApp links: {len(wa_links)}')
    for idx, l in enumerate(wa_links, 1):
        href = l.get('href', '')
        parsed = urllib.parse.urlparse(href)
        params = urllib.parse.parse_qs(parsed.query)
        msg = params.get('text', [''])[0]
        print(f'  [{idx}] Path: {parsed.path} | Query msg: "{msg}"')

    emails = [l for l in parser.links if 'mailto:' in l.get('href', '')]
    print(f'\nTotal Mailto links: {len(emails)}')
    for l in emails:
        print(f'  Href: {l.get("href")}')

    print('\n=== 3. TAXONOMY & MODULES CHECK ===')
    taxonomies = ['WMS', 'OMS', 'FMS', 'HRIS', 'EMS']
    for tax in taxonomies:
        matches = len(re.findall(r'\b' + tax + r'\b', html))
        print(f'Taxonomy {tax}: {matches} occurrences in index.html')

    print('\n=== 4. JSON-LD SCHEMAS CHECK ===')
    print(f'JSON-LD scripts found: {len(parser.scripts)}')
    for i, s in enumerate(parser.scripts):
        try:
            data = json.loads(s['content'])
            graph = data.get('@graph', [data])
            types = [item.get('@type') for item in graph if isinstance(item, dict)]
            print(f'  Schema #{i+1}: Valid JSON! Types: {types}')
            for item in graph:
                if isinstance(item, dict):
                    print(f'    Type: {item.get("@type")} -> ID: {item.get("@id")} Name: {item.get("name")}')
        except Exception as e:
            print(f'  Schema #{i+1} INVALID: {e}')

    print('\n=== 5. PRICING TIERS VERIFICATION ===')
    tiers = ['Trial', 'Starter', 'Growth', 'Pro', 'Enterprise']
    for tier in tiers:
        found_in_html = tier in html
        tier_wa_msg = f'paket {tier}'
        found_wa = any(tier_wa_msg.lower() in l.get('href', '').lower() for l in wa_links)
        print(f'Tier "{tier}": In HTML={found_in_html}, Dedicated WA Trigger={found_wa}')

    print('\n=== 6. LOGO & BRANDING USAGE IN DOM ===')
    logos = [img for img in parser.images if 'logo.png' in img.get('src', '')]
    print(f'Logo img tags found: {len(logos)}')
    for l in logos:
        print(f'  Logo src="{l.get("src")}" class="{l.get("class")}" alt="{l.get("alt")}"')

    favicons = [lk for lk in parser.link_tags if 'icon' in lk.get('rel', '')]
    print(f'Favicon link tags found: {len(favicons)}')
    for fav in favicons:
        print(f'  Favicon rel="{fav.get("rel")}" href="{fav.get("href")}"')

    og_images = [m for m in parser.meta_tags if 'image' in m.get('property', '') or 'image' in m.get('name', '')]
    print(f'OpenGraph/Meta image tags: {len(og_images)}')
    for og in og_images:
        print(f'  Meta property="{og.get("property")}" name="{og.get("name")}" content="{og.get("content")}"')

if __name__ == '__main__':
    main()
