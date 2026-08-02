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

        # Click email field at (700, 525)
        print("Clicking email field at (700, 525)...")
        await page.mouse.click(700, 525)
        await page.wait_for_timeout(300)
        await page.keyboard.type("inventorycontrolhai@gmail.com", delay=30)

        # Click password field at (700, 590)
        print("Clicking password field at (700, 590)...")
        await page.mouse.click(700, 590)
        await page.wait_for_timeout(300)
        await page.keyboard.type("Wjk01@", delay=30)

        # Click Masuk at (700, 665)
        print("Clicking Masuk at (700, 665)...")
        await page.mouse.click(700, 665)

        await page.wait_for_timeout(7000)

        s1 = os.path.join(out_dir, "coords_after_login.png")
        await page.screenshot(path=s1, full_page=True)
        print(f"Saved {s1}")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
