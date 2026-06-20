import asyncio, logging, sys, json
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from config import TV_USERNAME, TV_PASSWORD

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

WEBHOOK_URL = "http://100.109.179.25:50505/webhook"
ALERT_MSG = '{"symbol":"{{ticker}}","timeframe":"H4","price":{{close}},"tenkan":{{plot("Tenkan")}},"kijun":{{plot("Kijun")}},"senkouA":{{plot("Senkou A")}},"senkouB":{{plot("Senkou B")}},"direction":"{{plot("Signal")}}"'
SYMBOLS = ["XAUUSD", "BTCUSD", "EURUSD", "GBPUSD", "USDJPY", "AUDUSD", "XAGUSD", "US30"]
TV_SYMBOLS = {
    "XAUUSD": "OANDA:XAUUSD",
    "BTCUSD": "BITSTAMP:BTCUSD",
    "EURUSD": "OANDA:FX_EURUSD",
    "GBPUSD": "OANDA:FX_GBPUSD",
    "USDJPY": "OANDA:FX_USDJPY",
    "AUDUSD": "OANDA:FX_AUDUSD",
    "XAGUSD": "OANDA:XAGUSD",
    "US30": "TVC:DJI",
}
TIMEFRAME = "240"  # H4 in minutes

async def main():
    from playwright.async_api import async_playwright

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=False)
        ctx = await browser.new_context(viewport={"width": 1400, "height": 900})
        page = await ctx.new_page()
        page.on("response", lambda resp: log.debug(f"{resp.status} {resp.url}"))

        log.info("Login TV...")
        await page.goto("https://www.tradingview.com", timeout=60000)
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
                await page.wait_for_timeout(8000)
                log.info("Logged in")
        else:
            log.info("Already logged in")

        # Fetch existing alerts via TV internal API
        log.info("Fetching existing alerts...")
        alerts = await page.evaluate("""
            async () => {
                const resp = await fetch('https://www.tradingview.com/alert-manager/alerts', {
                    credentials: 'include'
                });
                return resp.json();
            }
        """)
        log.info(f"Found {len(alerts) if isinstance(alerts, list) else '?'} alerts")

        # Find existing XAUUSD alert to clone its settings
        existing_alerts = alerts if isinstance(alerts, list) else []
        template_alert = None
        for a in existing_alerts:
            if "XAUUSD" in a.get("symbol", "") or "XAUUSD" in str(a.get("ticker", "")):
                template_alert = a
                log.info(f"Found XAUUSD alert: id={a.get('id')}")
                break

        if not template_alert and len(existing_alerts) > 0:
            template_alert = existing_alerts[0]
            log.info(f"No XAUUSD alert found, using first alert: id={template_alert.get('id')}")

        # If we found any alert, update/duplicate
        if template_alert:
            alert_id = template_alert.get("id")
            
            # Update existing alert with correct webhook URL
            log.info(f"Updating alert {alert_id} with webhook URL...")
            update_payload = {**template_alert, "webhook_url": WEBHOOK_URL}
            # Remove fields that shouldn't be in update
            update_payload.pop("id", None)
            update_payload.pop("created", None)
            
            result = await page.evaluate("""
                async (args) => {
                    const resp = await fetch(`https://www.tradingview.com/alert-manager/alerts/${args.id}`, {
                        method: 'PUT',
                        headers: {'Content-Type': 'application/json'},
                        credentials: 'include',
                        body: JSON.stringify(args.payload)
                    });
                    return {status: resp.status, text: await resp.text()};
                }
            """, {"id": alert_id, "payload": update_payload})
            log.info(f"Update result: {result}")

        else:
            log.warning("No existing alerts found. Need to create from scratch.")
            # Create XAUUSD alert from scratch
            # This would need the condition_id from the Pine Script indicator
            # For now, navigate to chart and create via UI
            log.info("Opening XAUUSD chart to create alert...")
            await page.goto("https://www.tradingview.com/chart/?symbol=OANDA:XAUUSD&interval=240", timeout=60000)
            await page.wait_for_timeout(8000)
            
            # Open alert creation dialog
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
            cond = page.locator("text=Condition").first
            if await cond.is_visible(timeout=3000):
                await cond.click()
                await page.wait_for_timeout(1000)
                await page.keyboard.type("Ichimoku Signal", delay=20)
                await page.wait_for_timeout(1500)
                await page.keyboard.press("Enter")
                await page.wait_for_timeout(1000)
            
            # Fill webhook URL
            inputs = await page.locator("input").all()
            for inp in inputs:
                try:
                    placeholder = (await inp.get_attribute("placeholder")) or ""
                    if "webhook" in placeholder.lower():
                        await inp.fill(WEBHOOK_URL)
                        log.info("Webhook URL filled")
                except: pass
            
            # Fill message
            areas = await page.locator("textarea").all()
            for area in areas:
                try:
                    await area.fill(ALERT_MSG)
                    log.info("Alert message filled")
                except: pass
            
            # Save
            await page.keyboard.press("Control+Enter")
            await page.wait_for_timeout(3000)
            log.info("XAUUSD alert created!")

        log.info("Browser open — verify and duplicate manually if needed.")
        log.info("Press Ctrl+C in terminal to close browser after verifying.")
        await page.wait_for_timeout(120000)
        await browser.close()

asyncio.run(main())
