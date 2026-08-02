import asyncio
import os
import sys
from playwright.async_api import async_playwright

async def run():
    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=True,
            args=[
                '--no-sandbox',
                '--disable-setuid-sandbox',
                '--force-device-scale-factor=1.0',
            ]
        )
        context = await browser.new_context(viewport={'width': 1400, 'height': 900})
        page = await context.new_page()

        print("Navigating to https://mdhproduction.com/...")
        await page.goto("https://mdhproduction.com/", wait_until="networkidle", timeout=30000)
        await asyncio.sleep(2)

        # Enable Flutter web semantics
        await page.evaluate("""() => {
            const fltSemantics = document.querySelector('flt-glass-pane');
            if (fltSemantics) {
                const event = new CustomEvent('flutter-enable-semantics');
                window.dispatchEvent(event);
            }
        }""")
        await asyncio.sleep(2)

        # Login as Super Admin
        email_input = page.get_by_placeholder("Email / Phone / Username")
        if await email_input.count() > 0:
            await email_input.fill("inventorycontrolhai@gmail.com")
            await page.get_by_placeholder("Password").fill("Wjk01@")
            await page.get_by_role("button", name="LOGIN").click()
            print("Submitted login form...")
            await asyncio.sleep(5)

        # Navigate directly to Finance Report
        print("Navigating to /finance/report...")
        await page.goto("https://mdhproduction.com/#/finance/report", wait_until="networkidle", timeout=30000)
        await asyncio.sleep(6)

        # Capture initial view
        out_dir = r"C:\Users\budic\.gemini\antigravity\brain\29105c85-4f22-450f-97c1-fbf44836965e"
        shot1 = os.path.join(out_dir, "v48_verified_ringkasan_tab.png")
        await page.screenshot(path=shot1, full_page=False)
        print(f"Saved Ringkasan screenshot to {shot1}")

        # Click Tab Biaya (5th tab, tab index 4: Ringkasan, Marketplace, SKU, Arus Kas, Biaya, Laba Rugi)
        # Let's locate tab text "Biaya" or "Biaya Operasional"
        biaya_tab = page.get_by_text("Biaya", exact=False)
        if await biaya_tab.count() > 0:
            # Click Biaya tab
            for i in range(await biaya_tab.count()):
                txt = await biaya_tab.nth(i).inner_text()
                if "biaya" in txt.lower() and "operasional" not in txt.lower():
                    await biaya_tab.nth(i).click()
                    print(f"Clicked tab: {txt}")
                    break
            await asyncio.sleep(4)

        shot2 = os.path.join(out_dir, "v48_verified_biaya_tab.png")
        await page.screenshot(path=shot2, full_page=False)
        print(f"Saved Biaya tab screenshot to {shot2}")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(run())
