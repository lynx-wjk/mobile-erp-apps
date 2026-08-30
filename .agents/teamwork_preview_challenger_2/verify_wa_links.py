import sys
sys.path.insert(0, '.')
from tests.test_helpers import load_landing_page_dom, parse_whatsapp_url, scan_for_prohibited_terms
dom, html = load_landing_page_dom()
a_nodes = dom.root.find_all('a')
wa_links = [a.get_attr('href') for a in a_nodes if 'wa.me' in (a.get_attr('href') or '')]

print(f"Total wa.me links found in HTML: {len(wa_links)}")
for i, link in enumerate(wa_links):
    parsed = parse_whatsapp_url(link)
    has_consultant = "Tim Konsultan Mobile ERP" in parsed["decoded_text"]
    print(f"[{i+1}] {link}")
    print(f"    Phone: {parsed['phone']}")
    print(f"    Text: '{parsed['decoded_text']}'")
    print(f"    Has 'Tim Konsultan Mobile ERP': {has_consultant}")
