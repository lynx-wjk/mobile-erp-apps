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

        await page.evaluate("() => { const b = document.querySelector('flt-semantics-placeholder'); if (b) b.click(); }")
        await page.wait_for_timeout(300)

        await page.mouse.click(600, 470)
        await page.wait_for_timeout(200)
        await page.keyboard.type("inventorycontrolhai@gmail.com", delay=20)

        await page.mouse.click(600, 530)
        await page.wait_for_timeout(200)
        await page.keyboard.type("Wjk01@", delay=20)

        await page.mouse.click(600, 598)
        await page.wait_for_timeout(6000)

        print("Clicking Keuangan sidebar item...")
        await page.mouse.click(100, 240)
        # Wait 15 seconds for initial RPC call to load
        await page.wait_for_timeout(15000)

        s1 = os.path.join(out_dir, "v51_verified_ringkasan_tab.png")
        await page.screenshot(path=s1, full_page=True)
        print(f"Saved v51 Ringkasan screenshot to {s1}")

        # Click Tab Marketplace (x=100, y=86)
        print("Clicking Tab Marketplace...")
        await page.mouse.click(100, 86)
        await page.wait_for_timeout(5000)

        s2 = os.path.join(out_dir, "v51_verified_marketplace_tab.png")
        await page.screenshot(path=s2, full_page=True)
        print(f"Saved v51 Marketplace screenshot to {s2}")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
