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
        await page.wait_for_timeout(8000)

        out_dir = r"C:\Users\budic\.gemini\antigravity\brain\29105c85-4f22-450f-97c1-fbf44836965e"
        s1 = os.path.join(out_dir, "v47_initial_load.png")
        await page.screenshot(path=s1, full_page=True)
        print(f"Saved {s1}")

        # Check for inputs or click canvas
        inputs = await page.locator("input").all()
        print(f"Inputs found: {len(inputs)}")
        for idx, inp in enumerate(inputs):
            try:
                vis = await inp.is_visible()
                ptype = await inp.get_attribute("type")
                placeholder = await inp.get_attribute("placeholder")
                print(f"Input {idx}: type={ptype}, placeholder={placeholder}, visible={vis}")
            except Exception as e:
                print(f"Input {idx} error: {e}")

        # Try filling email and password by placeholder or type
        email_loc = page.locator("input[placeholder*='Email'], input[type='email'], input[type='text']").first
        if await email_loc.count() > 0:
            await email_loc.fill("inventorycontrolhai@gmail.com")
            print("Filled email!")

        pass_loc = page.locator("input[placeholder*='Password'], input[type='password']").first
        if await pass_loc.count() > 0:
            await pass_loc.fill("Wjk01@")
            print("Filled password!")

        login_btn = page.locator("button:has-text('Masuk'), button:has-text('Login'), div:has-text('Masuk')").last
        if await login_btn.count() > 0:
            await login_btn.click()
            print("Clicked login!")

        await page.wait_for_timeout(6000)

        s2 = os.path.join(out_dir, "v47_after_login.png")
        await page.screenshot(path=s2, full_page=True)
        print(f"Saved {s2}")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
