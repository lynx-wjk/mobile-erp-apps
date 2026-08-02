import asyncio
from playwright.async_api import async_playwright
import os

async def main():
    out_dir = r"C:\Users\budic\.gemini\antigravity\brain\29105c85-4f22-450f-97c1-fbf44836965e"
    
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        context = await browser.new_context(viewport={'width': 1400, 'height': 950})
        page = await context.new_page()

        print("Navigating to https://mdhproduction.com/...")
        await page.goto("https://mdhproduction.com/", wait_until="load")
        await page.wait_for_timeout(4000)

        # Trigger Flutter web semantics
        await page.evaluate("() => { const b = document.querySelector('flt-semantics-placeholder'); if (b) b.click(); }")
        await page.wait_for_timeout(300)

        # Fill credentials
        print("Filling login form...")
        await page.mouse.click(600, 470)
        await page.wait_for_timeout(300)
        await page.keyboard.type("inventorycontrolhai@gmail.com", delay=20)

        await page.mouse.click(600, 530)
        await page.wait_for_timeout(300)
        await page.keyboard.type("Wjk01@", delay=20)

        print("Submitting login...")
        await page.mouse.click(600, 598)
        await page.wait_for_timeout(10000)

        # Check if dashboard loaded by taking a draft screenshot
        draft_login = os.path.join(out_dir, "draft_after_login.png")
        await page.screenshot(path=draft_login)
        print(f"Login attempt saved to {draft_login}")

        print("Navigating to Keuangan page...")
        await page.mouse.click(100, 240)
        await page.wait_for_timeout(10000)

        tabs = [
            ("0_ringkasan", 32, 86),
            ("1_marketplace", 100, 86),
            ("2_sku", 156, 86),
            ("3_aruskas", 205, 86),
            ("4_biaya", 256, 86),
            ("5_labarugi", 308, 86),
            ("6_abnormal", 368, 86),
        ]

        for tab_name, x, y in tabs:
            print(f"Clicking tab {tab_name} at ({x}, {y})...")
            await page.mouse.click(x, y)
            await page.wait_for_timeout(7000)
            
            filepath = os.path.join(out_dir, f"ui_tab_{tab_name}.png")
            await page.screenshot(path=filepath, full_page=True)
            print(f"Saved {filepath}")

        await browser.close()
        print("Completed capturing all 7 finance tabs.")

if __name__ == "__main__":
    asyncio.run(main())
