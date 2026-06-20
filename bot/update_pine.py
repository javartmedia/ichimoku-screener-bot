import asyncio, logging, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from config import TV_USERNAME, TV_PASSWORD

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

CHART_URL = "https://www.tradingview.com/chart/2HiwlGRV/?symbol=OANDA%3AXAUUSD&interval=240"
PINE_PATH = Path(__file__).parent / "ichimoku_screener.pine"

async def main():
    script = PINE_PATH.read_text(encoding="utf-8")

    from playwright.async_api import async_playwright

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=False)
        ctx = await browser.new_context(viewport={"width": 1400, "height": 900})
        page = await ctx.new_page()

        log.info("Login...")
        await page.goto(CHART_URL, timeout=60000)
        await page.wait_for_timeout(8000)

        sign_in = page.locator("button:has-text('Sign In')").first
        if await sign_in.is_visible(timeout=3000):
            await sign_in.click()
            await page.wait_for_timeout(3000)
            email = page.locator("input[type='email']").first
            if await email.is_visible(timeout=5000):
                await email.fill(TV_USERNAME)
                await page.locator("input[type='password']").first.fill(TV_PASSWORD)
                await page.locator("button[type='submit']").first.click()
                await page.wait_for_timeout(8000)

        # Buka Pine Editor
        log.info("Buka Pine Editor via Ctrl+Shift+P...")
        await page.keyboard.press("Control+Shift+P")
        await page.wait_for_timeout(3000)
        await page.keyboard.type("Pine Editor", delay=20)
        await page.wait_for_timeout(2000)
        await page.keyboard.press("Enter")
        await page.wait_for_timeout(10000)

        # Tunggu editor benar-benar load
        log.info("Tunggu editor...")
        await page.wait_for_timeout(5000)

        # Method: Hapus konten lama, lalu ketik ulang via keyboard
        log.info("Bersihkan editor...")
        await page.keyboard.press("Control+A")
        await page.wait_for_timeout(1000)
        await page.keyboard.press("Delete")
        await page.wait_for_timeout(1000)

        log.info("Paste script baru...")
        await page.keyboard.insert_text(script)
        await page.wait_for_timeout(3000)

        log.info("Save...")
        await page.keyboard.press("Control+S")
        await page.wait_for_timeout(3000)

        # Cek apakah ada popup save (first time save = minta nama)
        name_input = page.locator("input[placeholder*='name'], input[placeholder*='Name']").first
        if await name_input.is_visible(timeout=3000):
            await name_input.fill("Ichimoku Screener H4")
            await page.wait_for_timeout(500)
            save_btn = page.locator("button:has-text('Save'), button:has-text('Simpan')").first
            if await save_btn.is_visible():
                await save_btn.click()
                await page.wait_for_timeout(3000)
            else:
                await page.keyboard.press("Enter")
                await page.wait_for_timeout(2000)

        log.info("Script berhasil diupdate! Cek Pine Editor — harusnya tidak ada error.")

        log.info("Browser tetap terbuka 30 detik...")
        await page.wait_for_timeout(30000)
        await browser.close()

asyncio.run(main())
