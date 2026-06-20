import asyncio, logging, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from config import TV_USERNAME, TV_PASSWORD

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

CHART_URL = "https://www.tradingview.com/chart/2HiwlGRV/?symbol=OANDA%3AXAUUSD&interval=240"
PINE_PATH = Path(__file__).parent / "ichimoku_screener.pine"
WEBHOOK_URL = "http://IP-LINUX-ANDA:50505/webhook"
ALERT_MSG = '{"symbol":"{{ticker}}","timeframe":"H4","close":{{close}},"timestamp":"{{time}}"}'

async def main():
    script = PINE_PATH.read_text(encoding="utf-8")

    from playwright.async_api import async_playwright

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=False)
        ctx = await browser.new_context(viewport={"width": 1400, "height": 900})
        page = await ctx.new_page()

        log.info("Login TV...")
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

        # Buka Pine Editor via keyboard
        log.info("Update Pine Script...")
        await page.keyboard.press("Control+Shift+P")
        await page.wait_for_timeout(3000)
        await page.keyboard.type("Pine Editor", delay=20)
        await page.wait_for_timeout(2000)
        await page.keyboard.press("Enter")
        await page.wait_for_timeout(8000)

        # Paste script
        await page.evaluate("(code) => navigator.clipboard.writeText(code)", script)
        await page.wait_for_timeout(500)
        await page.keyboard.press("Control+A")
        await page.wait_for_timeout(500)
        await page.keyboard.press("Control+V")
        await page.wait_for_timeout(2000)

        # Save
        await page.keyboard.press("Control+S")
        await page.wait_for_timeout(3000)
        log.info("Pine Script updated & saved")

        # Buka alert dialog
        log.info("Buat alert...")
        await page.goto(CHART_URL, timeout=60000)
        await page.wait_for_timeout(8000)

        await page.evaluate("""
            () => { try {
                if (window.tvWidget && window.tvWidget.activeChart) {
                    window.tvWidget.activeChart().executeActionById('createAlert');
                }
            } catch(e) {} }
        """)
        await page.wait_for_timeout(5000)

        # Set condition dropdown
        cond = page.locator("text=Condition, [class*='condition'], div:has-text('Condition')").first
        if await cond.is_visible(timeout=5000):
            await cond.click()
            await page.wait_for_timeout(1000)
            await page.keyboard.type("Ichimoku Signal", delay=20)
            await page.wait_for_timeout(1500)
            await page.keyboard.press("Enter")
            await page.wait_for_timeout(1000)

        # Find all text inputs and fill webhook URL & message
        inputs = await page.locator("input").all()
        for inp in inputs:
            try:
                placeholder = (await inp.get_attribute("placeholder")) or ""
                if "webhook" in placeholder.lower():
                    await inp.fill(WEBHOOK_URL)
                    log.info("Webhook URL filled")
            except: pass

        # Fill message (usually a textarea, not input)
        areas = await page.locator("textarea").all()
        for area in areas:
            try:
                text = (await area.input_value()) or ""
                if len(text) > 0 or "message" in ((await area.get_attribute("placeholder")) or "").lower():
                    await area.fill(ALERT_MSG)
                    log.info("Alert message filled")
            except: pass

        # Save
        await page.keyboard.press("Control+Enter")
        await page.wait_for_timeout(3000)
        log.info("Alert saved!")

        log.info("\n✅ Alert XAUUSD berhasil dibuat!")
        log.info("Browser masih terbuka — duplicate untuk simbol lain lewat panel alarm.")
        await page.wait_for_timeout(60000)
        await browser.close()

asyncio.run(main())
