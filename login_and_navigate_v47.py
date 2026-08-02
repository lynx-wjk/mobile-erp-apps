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

        # Click email field at (550, 520)
        print("Clicking email field at (550, 520)...")
        await page.mouse.click(550, 520)
        await page.wait_for_timeout(300)
        await page.keyboard.type("inventorycontrolhai@gmail.com", delay=20)

        # Click password field at (550, 590)
        print("Clicking password field at (550, 590)...")
        await page.mouse.click(550, 590)
        await page.wait_for_timeout(300)
        await page.keyboard.type("Wjk01@", delay=20)

        # Click Masuk at (500, 665)
        print("Clicking Masuk at (500, 665)...")
        await page.mouse.click(500, 665)

        await page.wait_for_timeout(6000)

        s1 = os.path.join(out_dir, "v47_real_dashboard.png")
        await page.screenshot(path=s1, full_page=True)
        print(f"Saved {s1}")

        # Navigate to Finance Report page
        print("Navigating to Finance Report page...")
        await page.goto("https://mdhproduction.com/#/finance/report", wait_until="networkidle")
        await page.wait_for_timeout(7000)

        s2 = os.path.join(out_dir, "v47_real_tab_0_ringkasan.png")
        await page.screenshot(path=s2, full_page=True)
        print(f"Saved {s2}")

        # Click Laba Rugi tab
        print("Clicking Laba Rugi tab...")
        await page.mouse.click(730, 160) # Click Laba Rugi tab header
        await page.wait_for_timeout(4000)

        # Click Rincian Rekonsiliasi header if present or click (700, 450)
        recon_el = page.locator("text=Rincian Rekonsiliasi").first
        if await recon_el.count() > 0:
            await recon_el.click()
            await page.wait_for_timeout(2000)

        s3 = os.path.join(out_dir, "v47_real_tab_labarugi_recon.png")
        await page.screenshot(path=s3, full_page=True)
        print(f"Saved {s3}")

        # Click Detail Per SKU tab
        print("Clicking Detail Per SKU tab...")
        await page.mouse.click(450, 160) # Click SKU tab header
        await page.wait_for_timeout(5000)

        s4 = os.path.join(out_dir, "v47_real_tab_sku_all.png")
        await page.screenshot(path=s4, full_page=True)
        print(f"Saved {s4}")

        # Click Belum Payout filter button
        unpaid_el = page.locator("text=Belum Payout").first
        if await unpaid_el.count() > 0:
            await unpaid_el.click()
            await page.wait_for_timeout(4000)
            s5 = os.path.join(out_dir, "v47_real_tab_sku_unpaid.png")
            await page.screenshot(path=s5, full_page=True)
            print(f"Saved {s5}")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
