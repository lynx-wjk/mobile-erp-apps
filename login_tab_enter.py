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

        # Double click email field at (550, 520)
        print("Double-clicking email field at (550, 520)...")
        await page.mouse.dblclick(550, 520)
        await page.wait_for_timeout(300)
        await page.keyboard.type("inventorycontrolhai@gmail.com", delay=30)
        await page.wait_for_timeout(300)

        # Press Tab to focus password field
        print("Pressing Tab...")
        await page.keyboard.press("Tab")
        await page.wait_for_timeout(300)
        await page.keyboard.type("Wjk01@", delay=30)
        await page.wait_for_timeout(300)

        # Press Enter or click Masuk
        print("Pressing Enter...")
        await page.keyboard.press("Enter")
        await page.wait_for_timeout(500)
        await page.mouse.click(500, 665)

        await page.wait_for_timeout(8000)

        s1 = os.path.join(out_dir, "v47_logged_in_tab_enter.png")
        await page.screenshot(path=s1, full_page=True)
        print(f"Saved {s1}")

        # Navigate to Finance Report page
        print("Navigating to Finance Report page...")
        await page.goto("https://mdhproduction.com/#/finance/report", wait_until="networkidle")
        await page.wait_for_timeout(8000)

        s2 = os.path.join(out_dir, "v47_finance_report_live.png")
        await page.screenshot(path=s2, full_page=True)
        print(f"Saved {s2}")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
