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
        keuangan = page.locator("text=Keuangan").first
        if await keuangan.count() > 0:
            await keuangan.click()
        else:
            await page.mouse.click(100, 240)

        await page.wait_for_timeout(6000)

        # Take Tab 0: Ringkasan screenshot
        s1 = os.path.join(out_dir, "v47_real_tab_0_ringkasan_live.png")
        await page.screenshot(path=s1, full_page=True)
        print(f"Saved {s1}")

        # Click Laba Rugi tab
        print("Clicking Laba Rugi tab...")
        laba = page.locator("text=Laba Rugi").first
        if await laba.count() > 0:
            await laba.click()
            await page.wait_for_timeout(4000)

            # Click Rincian Rekonsiliasi
            recon = page.locator("text=Rincian Rekonsiliasi").first
            if await recon.count() > 0:
                print("Expanding Rincian Rekonsiliasi...")
                await recon.click()
                await page.wait_for_timeout(2000)

            s2 = os.path.join(out_dir, "v47_real_tab_labarugi_recon_live.png")
            await page.screenshot(path=s2, full_page=True)
            print(f"Saved {s2}")

        # Click Detail Per SKU tab
        print("Clicking Detail Per SKU tab...")
        sku = page.locator("text=Detail Per SKU, text=Detail SKU").first
        if await sku.count() > 0:
            await sku.click()
            await page.wait_for_timeout(5000)

            s3 = os.path.join(out_dir, "v47_real_tab_sku_all_live.png")
            await page.screenshot(path=s3, full_page=True)
            print(f"Saved {s3}")

            # Click Belum Payout filter
            unpaid = page.locator("text=Belum Payout").first
            if await unpaid.count() > 0:
                print("Filtering SKU tab by Belum Payout...")
                await unpaid.click()
                await page.wait_for_timeout(4000)
                s4 = os.path.join(out_dir, "v47_real_tab_sku_unpaid_live.png")
                await page.screenshot(path=s4, full_page=True)
                print(f"Saved {s4}")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
