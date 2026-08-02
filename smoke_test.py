from playwright.sync_api import sync_playwright
import time
import os

ARTIFACT_DIR = 'C:\\Users\\budic\\.gemini\\antigravity\\brain\\d36bf797-7d30-468d-8ea9-75c2a9341233'

def click_text(page, text):
    script = f"""() => {{
        let nodes = document.querySelectorAll('flt-semantics, span');
        let bestNode = null;
        let minArea = Infinity;
        for (let node of nodes) {{
            if (node.textContent && node.textContent.includes('{text}')) {{
                let rect = node.getBoundingClientRect();
                let area = rect.width * rect.height;
                if (area > 0 && area < minArea) {{
                    minArea = area;
                    bestNode = node;
                }}
            }}
        }}
        if (bestNode) {{
            let rect = bestNode.getBoundingClientRect();
            return {{x: rect.left + rect.width / 2, y: rect.top + rect.height / 2}};
        }}
        return null;
    }}"""
    coords = page.evaluate(script)
    if coords:
        page.mouse.click(coords['x'], coords['y'])
        return True
    return False

def run():
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(viewport={'width': 1280, 'height': 720})
        
        page.goto('https://mdhproduction.com/')
        page.wait_for_load_state('networkidle')
        time.sleep(3)
        
        page.evaluate("document.querySelector('flt-semantics-placeholder').click()")
        time.sleep(2)
        
        page.fill('input[aria-label="Email atau username"]', 'happyaboutit')
        page.fill('input[aria-label="Password"]', 'Wjk01@')
        page.locator('text="Masuk"').first.click(force=True)
        
        time.sleep(10)
        
        click_text(page, 'Keuangan')
        time.sleep(10) # wait longer
        
        html = page.evaluate("document.querySelector('flt-semantics-host').innerHTML")
        with open('finance_dom_html.txt', 'w', encoding='utf-8') as f:
            f.write(html)
            
        page.screenshot(path=os.path.join(ARTIFACT_DIR, 'finance_html.png'), full_page=True)

        browser.close()

if __name__ == '__main__':
    run()
