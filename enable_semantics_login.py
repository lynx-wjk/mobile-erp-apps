import asyncio
from playwright.async_api import async_playwright
import os

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        context = await browser.new_context(viewport={'width': 1400, 'height': 900})
        page = await context.new_page()

        print("Navigating to https://mdhproduction.com/...")
        await page.goto("https://mdhproduction.com/", wait_until="load")
        await page.wait_for_timeout(6000)

        out_dir = r"C:\Users\budic\.gemini\antigravity\brain\29105c85-4f22-450f-97c1-fbf44836965e"

        # Enable accessibility/semantics in Flutter Web
        print("Enabling Flutter semantics...")
        await page.evaluate('''() => {
            const btn = document.querySelector('flt-semantics-placeholder');
            if (btn) btn.click();
            // or trigger semantics host
            const host = document.querySelector('flt-semantics-host');
            if (host) host.click();
        }''')
        await page.wait_for_timeout(1000)

        # Inspect semantics text nodes or inputs
        nodes = await page.evaluate('''() => {
            const els = Array.from(document.querySelectorAll('flt-semantics, input, textarea, [role="textbox"]'));
            return els.map(e => ({
                tag: e.tagName,
                role: e.getAttribute('role'),
                label: e.getAttribute('aria-label') || e.innerText,
                rect: e.getBoundingClientRect()
            }));
        }''')
        print(f"Semantics nodes found: {len(nodes)}")
        for n in nodes[:20]:
            print(n)

        # Click Email field (y=520, x=500)
        print("Clicking Email field at (500, 520)...")
        await page.mouse.click(500, 520)
        await page.wait_for_timeout(500)
        await page.keyboard.type("inventorycontrolhai@gmail.com", delay=30)
        await page.wait_for_timeout(500)

        # Click Password field (y=590, x=500)
        print("Clicking Password field at (500, 590)...")
        await page.mouse.click(500, 590)
        await page.wait_for_timeout(500)
        await page.keyboard.type("Wjk01@", delay=30)
        await page.wait_for_timeout(500)

        # Click Masuk (y=665, x=500)
        print("Clicking Masuk button at (500, 665)...")
        await page.mouse.click(500, 665)
        await page.wait_for_timeout(8000)

        s1 = os.path.join(out_dir, "v47_semantics_login_result.png")
        await page.screenshot(path=s1, full_page=True)
        print(f"Saved {s1}")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
