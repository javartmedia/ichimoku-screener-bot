import asyncio, logging, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from config import TV_USERNAME, TV_PASSWORD

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

SYMBOLS = [
    ("XAUUSD", "OANDA:XAUUSD"),
    ("BTCUSD", "BITSTAMP:BTCUSD"),
    ("EURUSD", "OANDA:EURUSD"),
    ("GBPUSD", "OANDA:GBPUSD"),
    ("USDJPY", "OANDA:USDJPY"),
    ("AUDUSD", "OANDA:AUDUSD"),
    ("XAGUSD", "OANDA:XAGUSD"),
    ("US30", "TVC:DJI"),
]

async def main():
    from playwright.async_api import async_playwright

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=False)
        page = await browser.new_page(viewport={"width": 1400, "height": 900})

        log.info("Login ke TV...")
        await page.goto("https://www.tradingview.com/chart/?symbol=OANDA:XAUUSD", timeout=60000)
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

        for name, tv_symbol in SYMBOLS:
            log.info(f"\n=== {name} ({tv_symbol}) ===")

            await page.goto(f"https://www.tradingview.com/chart/?symbol={tv_symbol}", timeout=60000)
            await page.wait_for_timeout(6000)

            # Tekan "/" untuk buka search indicator
            await page.keyboard.press("/")
            await page.wait_for_timeout(2000)

            # Ketik nama indicator
            await page.keyboard.type("Ichimoku Screener H4", delay=30)
            await page.wait_for_timeout(2000)

            # Enter untuk add
            await page.keyboard.press("Enter")
            await page.wait_for_timeout(3000)

            log.info(f"Indicator added to {name}")

        log.info("\n✅ Indicator terpasang di semua simbol!")
        log.info("\n📋 SEKARANG BUAT ALERT (1x, lalu duplicate):")
        log.info("1. Buka chart XAUUSD")
        log.info("2. Klik 🔔 Alarm")
        log.info("3. Condition: alert() function calls")
        log.info("4. Webhook URL: http://IP-LINUX-ANDA:50505/webhook")
        log.info("5. Save")
        log.info("6. Buka panel alarm → Duplicate → ganti symbol")
        log.info("")
        log.info("Browser akan ditutup 15 detik...")
        await page.wait_for_timeout(15000)
        await browser.close()

asyncio.run(main())
