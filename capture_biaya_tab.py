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
        await page.wait_for_timeout(5000)

        out_dir = r"C:\Users\budic\.gemini\antigravity\brain\29105c85-4f22-450f-97c1-fbf44836965e"

        # Enable Flutter semantics
        await page.evaluate("() => { const b = document.querySelector('flt-semantics-placeholder'); if (b) b.click(); }")
        await page.wait_for_timeout(300)

        # Login
        await page.mouse.click(600, 470)
        await page.wait_for_timeout(200)
        await page.keyboard.type("inventorycontrolhai@gmail.com", delay=20)

        await page.mouse.click(600, 530)
        await page.wait_for_timeout(200)
        await page.keyboard.type("Wjk01@", delay=20)

        await page.mouse.click(600, 598)
        await page.wait_for_timeout(6000)

        # Click 'Keuangan' on sidebar (x=100, y=240)
        print("Clicking Keuangan sidebar item...")
        await page.mouse.click(100, 240)

        # Wait for page data load
        await page.wait_for_timeout(8000)

        # Click Tab Biaya (5th tab in tab bar: x=256, y=86)
        print("Clicking Tab Biaya via coordinates (x=256, y=86)...")
        await page.mouse.click(256, 86)
        await page.wait_for_timeout(4000)

        s2 = os.path.join(out_dir, "v48_verified_biaya_tab_exact.png")
        await page.screenshot(path=s2, full_page=True)
        print(f"Saved Biaya tab screenshot to {s2}")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
