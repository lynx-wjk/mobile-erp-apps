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

        # Enable Flutter web semantics
        await page.evaluate("() => { const b = document.querySelector('flt-semantics-placeholder'); if (b) b.click(); }")
        await page.wait_for_timeout(500)

        # Click Email field at (600, 470)
        print("Clicking Email input at (600, 470)...")
        await page.mouse.click(600, 470)
        await page.wait_for_timeout(300)
        await page.keyboard.type("inventorycontrolhai@gmail.com", delay=20)
        await page.wait_for_timeout(300)

        # Click Password input at (600, 530)
        print("Clicking Password input at (600, 530)...")
        await page.mouse.click(600, 530)
        await page.wait_for_timeout(300)
        await page.keyboard.type("Wjk01@", delay=20)
        await page.wait_for_timeout(300)

        # Click Masuk button at (600, 598)
        print("Clicking Masuk button at (600, 598)...")
        await page.mouse.click(600, 598)
        await page.wait_for_timeout(7000)

        # Take logged-in dashboard screenshot
        s1 = os.path.join(out_dir, "v47_dashboard_authenticated.png")
        await page.screenshot(path=s1, full_page=True)
        print(f"Saved {s1}")

        # Navigate to Finance Report page
        print("Navigating to Finance Report page...")
        await page.goto("https://mdhproduction.com/#/finance/report", wait_until="networkidle")
        await page.wait_for_timeout(8000)

        # Take Tab 0: Ringkasan screenshot
        s2 = os.path.join(out_dir, "v47_live_tab_0_ringkasan.png")
        await page.screenshot(path=s2, full_page=True)
        print(f"Saved {s2}")

        # Click Laba Rugi tab
        print("Clicking Laba Rugi tab...")
        await page.click("text=Laba Rugi")
        await page.wait_for_timeout(4000)

        # Click Rincian Rekonsiliasi header to expand sub-fee breakdown
        recon_el = page.locator("text=Rincian Rekonsiliasi").first
        if await recon_el.count() > 0:
            print("Expanding Rincian Rekonsiliasi...")
            await recon_el.click()
            await page.wait_for_timeout(2000)

        # Take Tab Laba Rugi + Reconciliation screenshot
        s3 = os.path.join(out_dir, "v47_live_tab_labarugi_recon.png")
        await page.screenshot(path=s3, full_page=True)
        print(f"Saved {s3}")

        # Click Detail Per SKU tab
        print("Clicking Detail Per SKU tab...")
        sku_el = page.locator("text=Detail Per SKU").first
        if await sku_el.count() > 0:
            await sku_el.click()
            await page.wait_for_timeout(6000)

            s4 = os.path.join(out_dir, "v47_live_tab_sku_all.png")
            await page.screenshot(path=s4, full_page=True)
            print(f"Saved {s4}")

            # Click Belum Payout filter
            unpaid_btn = page.locator("text=Belum Payout").first
            if await unpaid_btn.count() > 0:
                print("Filtering SKU tab by Belum Payout...")
                await unpaid_btn.click()
                await page.wait_for_timeout(4000)
                s5 = os.path.join(out_dir, "v47_live_tab_sku_unpaid.png")
                await page.screenshot(path=s5, full_page=True)
                print(f"Saved {s5}")

            # Click Settled filter
            paid_btn = page.locator("text=Settled").first
            if await paid_btn.count() > 0:
                print("Filtering SKU tab by Settled...")
                await paid_btn.click()
                await page.wait_for_timeout(4000)
                s6 = os.path.join(out_dir, "v47_live_tab_sku_settled.png")
                await page.screenshot(path=s6, full_page=True)
                print(f"Saved {s6}")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
