import logging
from pathlib import Path

from config import BOT_TOKEN, CHAT_ID

log = logging.getLogger(__name__)

_MSG_TEMPLATE = """{direction_emoji} <b>{direction} SIGNAL</b> · {timeframe}
━━━━━━━━━━━━━━━
<b>Symbol</b>  : {symbol}
<b>Price</b>   : {price}
<b>Tenkan</b>  : {tenkan}
<b>Kijun</b>   : {kijun}
<b>Cloud</b>   : {cloud_status} ({cloud_arrow} S-A / S-B)
━━━━━━━━━━━━━━━"""


def _format_price(val: float) -> str:
    if val == 0:
        return "-"
    if val > 100:
        return f"${val:,.2f}"
    if val > 1:
        return f"${val:.5f}"
    return f"${val:.5f}"


async def send_signal(
    direction: str,
    symbol: str,
    timeframe: str,
    price: float,
    tenkan: float,
    kijun: float,
    senkouA: float,
    senkouB: float,
    screenshot_path: str | None = None,
):
    if not BOT_TOKEN or not CHAT_ID:
        log.warning("BOT_TOKEN or CHAT_ID not set. Skipping Telegram.")
        return

    is_buy = direction.upper() == "BUY"
    emoji = "🟢" if is_buy else "🔴"
    cloud_status = "Bullish" if senkouA > senkouB else "Bearish"
    cloud_arrow = "▲" if senkouA > senkouB else "▼"

    text = _MSG_TEMPLATE.format(
        direction_emoji=emoji,
        direction=direction.upper(),
        timeframe=timeframe,
        symbol=symbol,
        price=_format_price(price),
        tenkan=_format_price(tenkan),
        kijun=_format_price(kijun),
        cloud_status=cloud_status,
        cloud_arrow=cloud_arrow,
    )

    try:
        import telegram

        bot = telegram.Bot(token=BOT_TOKEN)
        chat_id = CHAT_ID

        if screenshot_path and Path(screenshot_path).exists():
            with open(screenshot_path, "rb") as f:
                await bot.send_photo(chat_id=chat_id, photo=f, caption=text, parse_mode="HTML")
            log.info(f"Sent signal with screenshot to {chat_id}")
        else:
            await bot.send_message(chat_id=chat_id, text=text, parse_mode="HTML")
            log.info(f"Sent signal text to {chat_id}")
    except Exception as e:
        log.error(f"Failed to send Telegram: {e}")
