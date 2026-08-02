import asyncio
from playwright.async_api import async_playwright

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page(viewport={'width': 1400, 'height': 900})
        await page.goto("https://mdhproduction.com/", wait_until="load")
        await page.wait_for_timeout(6000)

        # Inspect all input elements or flt-semantics-host
        inputs = await page.evaluate('''() => {
            const els = Array.from(document.querySelectorAll('input, textarea, [contenteditable="true"]'));
            return els.map(e => ({
                tag: e.tagName,
                type: e.type,
                placeholder: e.placeholder,
                outer: e.outerHTML,
                rect: e.getBoundingClientRect()
            }));
        }''')
        print("DOM Inputs found:", len(inputs))
        for i in inputs:
            print(i)

        # Click center of Email box (500, 520) and inspect active element
        await page.mouse.click(500, 520)
        await page.wait_for_timeout(500)
        active = await page.evaluate('() => document.activeElement ? document.activeElement.outerHTML : "none"')
        print("Active element after clicking (500, 520):", active)

        await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
