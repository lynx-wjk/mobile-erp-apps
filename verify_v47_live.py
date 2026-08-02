import asyncio
from playwright.async_api import async_playwright
import os

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        context = await browser.new_context(viewport={'width': 1400, 'height': 900})
        page = await context.new_page()

        print("Navigating to https://mdhproduction.com/#/login...")
        await page.goto("https://mdhproduction.com/#/login", wait_until="networkidle")
        await page.wait_for_timeout(3000)

        # Login
        email_input = page.locator("input[type='email'], input[type='text']").first
        password_input = page.locator("input[type='password']").first
        await email_input.fill("inventorycontrolhai@gmail.com")
        await password_input.fill("Wjk01@")

        login_button = page.locator("button:has-text('Masuk'), button:has-text('Login')").first
        await login_button.click()
        print("Clicked login button...")

        await page.wait_for_timeout(5000)

        print("Navigating to Finance Report page...")
        await page.goto("https://mdhproduction.com/#/finance/report", wait_until="networkidle")
        await page.wait_for_timeout(6000)

        # Take screenshot of Ringkasan tab
        out_dir = r"C:\Users\budic\.gemini\antigravity\brain\29105c85-4f22-450f-97c1-fbf44836965e"
        r1 = os.path.join(out_dir, "v47_tab_0_ringkasan.png")
        await page.screenshot(path=r1, full_page=True)
        print(f"Saved {r1}")

        # Click Laba Rugi tab
        laba_tab = page.locator("text=Laba Rugi").first
        if await laba_tab.count() > 0:
            await laba_tab.click()
            await page.wait_for_timeout(3000)
            
            # Click expand Rincian Rekonsiliasi
            recon_btn = page.locator("text=Rincian Rekonsiliasi").first
            if await recon_btn.count() > 0:
                await recon_btn.click()
                await page.wait_for_timeout(2000)

            r2 = os.path.join(out_dir, "v47_tab_labarugi_recon.png")
            await page.screenshot(path=r2, full_page=True)
            print(f"Saved {r2}")

        # Click Detail Per SKU tab
        sku_tab = page.locator("text=Detail Per SKU, text=Detail SKU").first
        if await sku_tab.count() > 0:
            await sku_tab.click()
            await page.wait_for_timeout(5000)

            r3 = os.path.join(out_dir, "v47_tab_sku_all.png")
            await page.screenshot(path=r3, full_page=True)
            print(f"Saved {r3}")

            # Click Belum Payout filter
            unpaid_btn = page.locator("button:has-text('Belum Payout'), text=Belum Payout").first
            if await unpaid_btn.count() > 0:
                await unpaid_btn.click()
                await page.wait_for_timeout(4000)
                r4 = os.path.join(out_dir, "v47_tab_sku_unpaid.png")
                await page.screenshot(path=r4, full_page=True)
                print(f"Saved {r4}")

            # Click Settled filter
            paid_btn = page.locator("button:has-text('Settled'), text=Settled").first
            if await paid_btn.count() > 0:
                await paid_btn.click()
                await page.wait_for_timeout(4000)
                r5 = os.path.join(out_dir, "v47_tab_sku_settled.png")
                await page.screenshot(path=r5, full_page=True)
                print(f"Saved {r5}")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
