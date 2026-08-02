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
        await page.wait_for_timeout(300)

        # Fill credentials
        print("2. Logging in...")
        await page.mouse.click(600, 470)
        await page.wait_for_timeout(200)
        await page.keyboard.type("inventorycontrolhai@gmail.com", delay=20)

        await page.mouse.click(600, 530)
        await page.wait_for_timeout(200)
        await page.keyboard.type("Wjk01@", delay=20)

        await page.mouse.click(600, 598)
        await page.wait_for_timeout(8000)

        print("3. Navigating to Keuangan page...")
        await page.mouse.click(100, 240)
        await page.wait_for_timeout(10000)

        tab_names = [
            "0_ringkasan",
            "1_marketplace",
            "2_sku",
            "3_aruskas",
            "4_biaya",
            "5_labarugi",
            "6_abnormal",
        ]

        for idx, tab_name in enumerate(tab_names):
            print(f"Switching to tab index {idx} ({tab_name})...")
            
            # Click tab by evaluation of Flutter semantics or exact coordinate fallback
            clicked = await page.evaluate(f"""(tabIndex) => {{
                const semantics = Array.from(document.querySelectorAll('flt-semantics'));
                const tabs = semantics.filter(el => el.getAttribute('role') === 'tab' || (el.innerText && el.innerText.trim() === '{tab_name.split("_")[1]}'));
                if (tabs[tabIndex]) {{
                    tabs[tabIndex].click();
                    return true;
                }}
                return false;
            }}""", idx)

            if not clicked:
                # Coordinate fallback
                coords = [(32,86), (100,86), (156,86), (205,86), (256,86), (308,86), (368,86)]
                cx, cy = coords[idx]
                await page.mouse.click(cx, cy)

            await page.wait_for_timeout(7000)

            filepath = os.path.join(out_dir, f"verified_tab_{tab_name}.png")
            await page.screenshot(path=filepath, full_page=True)
            print(f"Saved {filepath}")

        await browser.close()
        print("Done capturing all 7 tabs!")

if __name__ == "__main__":
    asyncio.run(main())
