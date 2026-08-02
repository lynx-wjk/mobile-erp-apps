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

        # Click on 'Email atau username'
        print("Clicking Email field...")
        email_text = page.locator("text=Email atau username").first
        if await email_text.count() > 0:
            await email_text.click()
            await page.wait_for_timeout(500)
            await page.keyboard.type("inventorycontrolhai@gmail.com")
            print("Typed email!")

        # Click on 'Password'
        print("Clicking Password field...")
        pass_text = page.locator("text=Password").first
        if await pass_text.count() > 0:
            await pass_text.click()
            await page.wait_for_timeout(500)
            await page.keyboard.type("Wjk01@")
            print("Typed password!")

        # Click 'Masuk'
        print("Clicking Masuk button...")
        masuk_btn = page.locator("text=Masuk").first
        if await masuk_btn.count() > 0:
            await masuk_btn.click()
            print("Clicked Masuk!")

        await page.wait_for_timeout(7000)

        s1 = os.path.join(out_dir, "v47_dashboard_logged_in.png")
        await page.screenshot(path=s1, full_page=True)
        print(f"Saved {s1}")

        # Navigate to Finance Report
        print("Navigating to Finance Report...")
        await page.goto("https://mdhproduction.com/#/finance/report", wait_until="networkidle")
        await page.wait_for_timeout(7000)

        s2 = os.path.join(out_dir, "v47_tab_0_ringkasan.png")
        await page.screenshot(path=s2, full_page=True)
        print(f"Saved {s2}")

        # Click Laba Rugi tab
        laba_tab = page.locator("text=Laba Rugi").first
        if await laba_tab.count() > 0:
            await laba_tab.click()
            await page.wait_for_timeout(4000)

            # Click Rincian Rekonsiliasi
            recon_btn = page.locator("text=Rincian Rekonsiliasi").first
            if await recon_btn.count() > 0:
                await recon_btn.click()
                await page.wait_for_timeout(2000)

            s3 = os.path.join(out_dir, "v47_tab_labarugi_recon.png")
            await page.screenshot(path=s3, full_page=True)
            print(f"Saved {s3}")

        # Click Detail Per SKU tab
        sku_tab = page.locator("text=Detail Per SKU, text=Detail SKU").first
        if await sku_tab.count() > 0:
            await sku_tab.click()
            await page.wait_for_timeout(5000)

            s4 = os.path.join(out_dir, "v47_tab_sku_all.png")
            await page.screenshot(path=s4, full_page=True)
            print(f"Saved {s4}")

            # Click Belum Payout filter
            unpaid_btn = page.locator("text=Belum Payout").first
            if await unpaid_btn.count() > 0:
                await unpaid_btn.click()
                await page.wait_for_timeout(4000)
                s5 = os.path.join(out_dir, "v47_tab_sku_unpaid.png")
                await page.screenshot(path=s5, full_page=True)
                print(f"Saved {s5}")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
