from playwright.sync_api import sync_playwright
import os

html_path = os.path.abspath('slides.html')
pdf_path = os.path.abspath('Portfolio_Deck.pdf')

with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page()
    page.goto(f'file://{html_path}', wait_until='networkidle')
    
    # 1080px is 11.25in at 96 DPI. PDF pages will exactly match the .slide div dimensions.
    # We can use print_to_pdf with width/height in px or inches.
    page.pdf(
        path=pdf_path,
        width="1080px",
        height="1080px",
        print_background=True,
        margin={"top": "0", "right": "0", "bottom": "0", "left": "0"},
        prefer_css_page_size=True
    )
    browser.close()

print(f"Generated PDF: {pdf_path}")
