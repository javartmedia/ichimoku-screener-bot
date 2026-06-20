import json
import logging
from fastapi import FastAPI, Request
import uvicorn

from config import SERVER_PORT
from telegram_bot import send_signal
from screenshot import take_screenshot

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger(__name__)

app = FastAPI(title="Ichimoku Screener Bot")

@app.get("/webhook")
async def webhook_get():
    return {"message": "This endpoint accepts POST requests from TradingView alerts. Use /health for status."}

@app.post("/webhook")
async def webhook(request: Request):
    try:
        raw = await request.body()
        data = json.loads(raw)
    except Exception as e:
        log.error(f"Invalid payload: {e}")
        return {"ok": False, "error": "invalid_json"}

    direction = str(data.get("direction", "NONE")).strip()
    if direction == "1":
        direction = "BUY"
    elif direction == "-1":
        direction = "SELL"
    if direction not in ("BUY", "SELL"):
        return {"ok": True, "skipped": True}

    symbol = data.get("symbol", "???")
    tf = data.get("timeframe", "H4")
    price = data.get("price", 0)
    tenkan = data.get("tenkan", 0)
    kijun = data.get("kijun", 0)
    senkouA = data.get("senkouA", 0)
    senkouB = data.get("senkouB", 0)

    log.info(f"SIGNAL {direction} {symbol} @ {price}")

    screenshot_path = await take_screenshot(symbol, tf)

    await send_signal(
        direction=direction,
        symbol=symbol,
        timeframe=tf,
        price=price,
        tenkan=tenkan,
        kijun=kijun,
        senkouA=senkouA,
        senkouB=senkouB,
        screenshot_path=screenshot_path,
    )

    return {"ok": True}


@app.get("/health")
async def health():
    return {"status": "ok"}


if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=SERVER_PORT, log_level="info")
