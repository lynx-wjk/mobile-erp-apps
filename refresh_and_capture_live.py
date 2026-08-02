import asyncio
from playwright.async_api import async_playwright
import os

async def main():
    out_dir = r"C:\Users\budic\.gemini\antigravity\brain\29105c85-4f22-450f-97c1-fbf44836965e"
    
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        context = await browser.new_context(viewport={'width': 1400, 'height': 900})
        page = await context.new_page()

        print("1. Navigating to https://mdhproduction.com/...")
        await page.goto("https://mdhproduction.com/", wait_until="load")
        await page.wait_for_timeout(5000)

        # Trigger Flutter web semantics
        await page.evaluate("() => { const b = document.querySelector('flt-semantics-placeholder'); if (b) b.click(); }")
        await page.wait_for_timeout(500)

        # Fill credentials
        print("2. Logging in...")
        await page.mouse.click(600, 470)
        await page.wait_for_timeout(200)
        await page.keyboard.type("inventorycontrolhai@gmail.com", delay=20)

        await page.mouse.click(600, 530)
        await page.wait_for_timeout(200)
        await page.keyboard.type("Wjk01@", delay=20)

        await page.mouse.click(600, 598)
        await page.wait_for_timeout(10000)

        # Navigate to Keuangan - click on sidebar "Keuangan" text
        print("3. Navigating to Keuangan page...")
        # Try clicking on the "Keuangan" text in the sidebar
        await page.mouse.click(110, 218)
        await page.wait_for_timeout(3000)
        
        # Take a debug screenshot to see current state
        debug_path = os.path.join(out_dir, "debug_after_keuangan_click.png")
        await page.screenshot(path=debug_path, full_page=True)
        print(f"Debug: {debug_path}")
        
        # If we're still on dashboard, try navigating directly via URL
        current_url = page.url
        print(f"Current URL: {current_url}")
        
        if "keuangan" not in current_url.lower() and "finance" not in current_url.lower():
            print("Direct click didn't work, trying URL navigation...")
            await page.goto("https://mdhproduction.com/#/keuangan", wait_until="load")
            await page.wait_for_timeout(5000)
            current_url = page.url
            print(f"After URL nav: {current_url}")
        
        # Wait for RPC data to load (v9b takes ~100s)
        print("4. Waiting for finance data to load (up to 120s)...")
        await page.wait_for_timeout(120000)

        # Capture Ringkasan
        filepath_ringkasan = os.path.join(out_dir, "v9b_ringkasan.png")
        await page.screenshot(path=filepath_ringkasan, full_page=True)
        print(f"Saved {filepath_ringkasan}")

        # Switch to Marketplace tab - click "Marketplace" tab text
        print("5. Switching to Marketplace tab...")
        # The tab bar is at the top: Ringkasan | Marketplace | SKU | ...
        await page.mouse.click(139, 75)
        await page.wait_for_timeout(5000)

        filepath_mp = os.path.join(out_dir, "v9b_marketplace.png")
        await page.screenshot(path=filepath_mp, full_page=True)
        print(f"Saved {filepath_mp}")

        await browser.close()
        print("Completed refresh and capture.")

if __name__ == "__main__":
    asyncio.run(main())
