import os
from dotenv import load_dotenv

load_dotenv()

BOT_TOKEN = os.getenv("BOT_TOKEN", "")
CHAT_ID = os.getenv("CHAT_ID", "")
TV_USERNAME = os.getenv("TV_USERNAME", "")
TV_PASSWORD = os.getenv("TV_PASSWORD", "")
SERVER_PORT = int(os.getenv("SERVER_PORT", "50505"))

SYMBOLS = [
    "XAUUSD",
    "BTCUSD",
    "EURUSD",
    "GBPUSD",
    "USDJPY",
    "AUDUSD",
    "XAGUSD",
    "US30",
]

TIMEFRAME = "H4"
