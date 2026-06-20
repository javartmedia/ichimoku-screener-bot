import asyncio, logging, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from config import TV_USERNAME, TV_PASSWORD

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

WEBHOOK_URL = "http://100.109.179.25:50505/webhook"
ALERT_MSG = '{"symbol":"{{ticker}}","timeframe":"H4","price":{{close}},"tenkan":{{plot("Tenkan-sen")}},"kijun":{{plot("Kijun-sen")}},"senkouA":{{plot("Senkou A")}},"senkouB":{{plot("Senkou B")}},"direction":"{{plot("Signal")}}"}'
PINE_PATH = Path(__file__).parent / "ichimoku_screener.pine"

SYMBOLS = [
    ("XAUUSD", "OANDA:XAUUSD"),
    ("BTCUSD", "BITSTAMP:BTCUSD"),
    ("EURUSD", "OANDA:FX_EURUSD"),
    ("GBPUSD", "OANDA:FX_GBPUSD"),
    ("USDJPY", "OANDA:FX_USDJPY"),
    ("AUDUSD", "OANDA:FX_AUDUSD"),
    ("XAGUSD", "OANDA:XAGUSD"),
    ("US30", "TVC:DJI"),
]

async def create_alert_for_symbol(page, symbol, tv_symbol):
    log.info(f"=== Creating alert for {symbol} ({tv_symbol}) ===")
    chart_url = f"https://www.tradingview.com/chart/?symbol={tv_symbol}&interval=240"
    await page.goto(chart_url, timeout=60000)
    await page.wait_for_timeout(8000)

    await page.evaluate("""
        () => {
            try {
                if (window.tvWidget && window.tvWidget.activeChart) {
                    window.tvWidget.activeChart().executeActionById('createAlert');
                }
            } catch(e) {}
        }
    """)
    await page.wait_for_timeout(5000)

    # Select condition
    try:
        cond_trigger = page.locator("div:has-text('Condition'), [class*='condition']").first
        if await cond_trigger.is_visible(timeout=3000):
            await cond_trigger.click()
            await page.wait_for_timeout(1000)
            await page.keyboard.type("Ichimoku Signal", delay=15)
            await page.wait_for_timeout(2000)
            await page.keyboard.press("Enter")
            await page.wait_for_timeout(1000)
    except:
        pass

    # Webhook checkbox
    try:
        for el in await page.locator("label, div[role='label'], span").all():
            txt = ((await el.text_content()) or "").lower()
            if "webhook" in txt:
                cb = el.locator("input[type='checkbox']")
                if await cb.count() > 0 and not await cb.is_checked():
                    await cb.check()
                    await page.wait_for_timeout(500)
    except:
        pass

    # Webhook URL input
    for inp in await page.locator("input:not([type='checkbox'])").all():
        try:
            ph = (await inp.get_attribute("placeholder")) or ""
            typ = (await inp.get_attribute("type")) or ""
            if "webhook" in ph.lower() or "url" in ph.lower() or typ == "url":
                await inp.fill(WEBHOOK_URL)
        except:
            pass

    # Message textarea
    for area in await page.locator("textarea").all():
        try:
            await area.fill("")
            await area.fill(ALERT_MSG)
        except:
            pass

    await page.keyboard.press("Control+Enter")
    await page.wait_for_timeout(5000)
    log.info(f"Alert for {symbol} saved!")

async def main():
    from playwright.async_api import async_playwright

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=False)
        ctx = await browser.new_context(viewport={"width": 1400, "height": 900})
        page = await ctx.new_page()

        log.info("Login TV...")
        await page.goto("https://www.tradingview.com/chart/?symbol=OANDA:XAUUSD&interval=240", timeout=60000)
        await page.wait_for_timeout(5000)

        sign_in = page.locator("button:has-text('Sign In')").first
        if await sign_in.is_visible(timeout=3000):
            await sign_in.click()
            await page.wait_for_timeout(3000)
            email = page.locator("input[type='email']").first
            if await email.is_visible(timeout=5000):
                await email.fill(TV_USERNAME)
                await page.locator("input[type='password']").first.fill(TV_PASSWORD)
                await page.locator("button[type='submit']").first.click()
                await page.wait_for_timeout(10000)
                log.info("Logged in")
        else:
            log.info("Already logged in")

        # Step 1: Update Pine Script
        log.info("=== Updating Pine Script ===")
        script = PINE_PATH.read_text(encoding="utf-8")
        await page.keyboard.press("Control+Shift+P")
        await page.wait_for_timeout(3000)
        await page.keyboard.type("Pine Editor", delay=20)
        await page.wait_for_timeout(2000)
        await page.keyboard.press("Enter")
        await page.wait_for_timeout(8000)

        await page.evaluate("(code) => navigator.clipboard.writeText(code)", script)
        await page.wait_for_timeout(500)
        await page.keyboard.press("Control+A")
        await page.wait_for_timeout(500)
        await page.keyboard.press("Control+V")
        await page.wait_for_timeout(2000)
        await page.keyboard.press("Control+S")
        await page.wait_for_timeout(5000)
        log.info("Pine Script updated!")

        # Step 2: Create alerts for all symbols
        for symbol, tv_symbol in SYMBOLS:
            await create_alert_for_symbol(page, symbol, tv_symbol)

        log.info("\n✅ All 8 alerts created!")
        log.info("Browser will close in 30s...")
        await page.wait_for_timeout(30000)
        await browser.close()

asyncio.run(main())
