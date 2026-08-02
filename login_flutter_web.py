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

        # Click email field at (550, 515)
        print("Clicking email field at (550, 515)...")
        await page.mouse.click(550, 515)
        await page.wait_for_timeout(300)
        # Select all and delete if any text exists, then type
        await page.keyboard.press("Control+A")
        await page.keyboard.press("Backspace")
        await page.keyboard.type("inventorycontrolhai@gmail.com", delay=20)

        # Click password field at (550, 585)
        print("Clicking password field at (550, 585)...")
        await page.mouse.click(550, 585)
        await page.wait_for_timeout(300)
        await page.keyboard.press("Control+A")
        await page.keyboard.press("Backspace")
        await page.keyboard.type("Wjk01@", delay=20)

        # Click Masuk at (500, 665)
        print("Clicking Masuk at (500, 665)...")
        await page.mouse.click(500, 665)

        await page.wait_for_timeout(8000)

        s1 = os.path.join(out_dir, "v47_real_dashboard_success.png")
        await page.screenshot(path=s1, full_page=True)
        print(f"Saved {s1}")

        # Navigate directly to Finance Report page
        print("Navigating to Finance Report page...")
        await page.goto("https://mdhproduction.com/#/finance/report", wait_until="networkidle")
        await page.wait_for_timeout(8000)

        s2 = os.path.join(out_dir, "v47_real_tab_0_ringkasan_success.png")
        await page.screenshot(path=s2, full_page=True)
        print(f"Saved {s2}")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
