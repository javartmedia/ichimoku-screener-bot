import logging
import asyncio
from pathlib import Path

from config import SYMBOLS, TIMEFRAME, TV_USERNAME, TV_PASSWORD

log = logging.getLogger(__name__)
SCREENSHOT_DIR = Path(__file__).parent / "screenshots"

_browser = None
_page = None


async def _ensure_browser():
    global _browser, _page
    if _browser is not None:
        return

    from playwright.async_api import async_playwright

    p = await async_playwright().start()
    _browser = await p.chromium.launch(headless=True)
    _page = await _browser.new_page(viewport={"width": 1280, "height": 720})
    await _login_tv()


async def _login_tv():
    if not TV_USERNAME or not TV_PASSWORD:
        log.warning("TV credentials not set, screenshot will skip login")
        return

    global _page
    try:
        # Coba langsung ke chart — kalau sudah login cookie, langsung masuk
        await _page.goto("https://www.tradingview.com/chart/?symbol=OANDA:XAUUSD", timeout=30000)
        await _page.wait_for_timeout(5000)

        # Cek apakah ada tombol sign-in (artinya belum login)
        sign_in_btn = _page.locator("button:has-text('Sign In'), a:has-text('Sign In'), span:has-text('Sign In'), div:has-text('Sign In')").first
        if await sign_in_btn.is_visible(timeout=3000):
            await sign_in_btn.click()
            await _page.wait_for_timeout(3000)

            # Isi form login
            await _page.fill('input[type="email"], input[name="email"], input[placeholder*="mail"]', TV_USERNAME)
            await _page.fill('input[type="password"], input[name="password"], input[placeholder*="password"]', TV_PASSWORD)
            await _page.click('button[type="submit"]')
            await _page.wait_for_timeout(5000)
            log.info("Logged into TradingView via sign-in button")
        else:
            log.info("Already logged in to TradingView")

    except Exception as e:
        log.warning(f"Login note: {e}")
        # Mungkin sudah login, lanjutkan
        pass


async def take_screenshot(symbol: str, timeframe: str = TIMEFRAME) -> str | None:
    try:
        SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)
        filename = f"{symbol}_{timeframe}.png"
        filepath = str(SCREENSHOT_DIR / filename)

        await _ensure_browser()

        tv_symbol = symbol
        if symbol == "US30":
            tv_symbol = "TVC:DJI"
        elif symbol == "XAUUSD":
            tv_symbol = "OANDA:XAUUSD"
        elif symbol == "XAGUSD":
            tv_symbol = "OANDA:XAGUSD"
        elif symbol == "BTCUSD":
            tv_symbol = "BITSTAMP:BTCUSD"
        elif symbol in ["EURUSD", "GBPUSD", "USDJPY", "AUDUSD"]:
            tv_symbol = f"OANDA:{symbol}"

        chart_url = f"https://www.tradingview.com/chart/?symbol={tv_symbol}&interval={timeframe.lower()}"
        await _page.goto(chart_url, timeout=60000)
        await _page.wait_for_timeout(8000)

        chart_area = _page.locator("div[class*='chart-container'], div[class*='layout__area'], div[id*='tv_chart_container']").first
        if await chart_area.is_visible(timeout=5000):
            await chart_area.screenshot(path=filepath)
        else:
            await _page.screenshot(path=filepath)

        log.info(f"Screenshot saved: {filepath}")
        return filepath

    except Exception as e:
        log.error(f"Screenshot failed for {symbol}: {e}")
        return None


async def close_browser():
    global _browser, _page
    if _browser:
        await _browser.close()
        _browser = None
        _page = None
