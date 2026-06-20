#property strict
#property version   "2.00"
#property description "Ichimoku multi-symbol autopilot v2 — ATR SL, risk sizing, trailing, D1 filter"

#include <Trade/Trade.mqh>

input string InpSymbols = ""; // kosong = pakai mode otomatis (lihat InpAllBrokerSymbols)
input bool   InpAllBrokerSymbols = true; // true=semua simbol broker, false=hanya Market Watch

// --- Timeframe ---
input ENUM_TIMEFRAMES InpTimeframe       = PERIOD_H4;   // TF entry Ichimoku

input int InpTimerSeconds = 60;
input int InpTenkan = 9;
input int InpKijun = 26;
input int InpSenkouB = 52;
input bool InpUseFutureKumoConfirm = true;

// --- Risk Management ---
input double InpRiskPercent     = 1.0;   // Risk per trade (% dari balance)
input double InpMinLotSize      = 0.01;  // Lot minimum
input double InpMaxLotSize      = 5.0;   // Lot maksimum
input int    InpMaxOpenTrades   = 0;     // Max posisi terbuka (0 = tidak dibatasi)
input double InpMaxDailyLossPct = 3.0;   // Max daily loss (% dari balance) → stop trading
input double InpMaxDrawdownPct  = 10.0;  // Max drawdown (% dari balance) → pause EA

// --- SL ---
input bool   InpUseATRSL        = true;   // SL berbasis ATR (lebih adaptif)
input int    InpATRPeriod       = 14;     // Periode ATR
input double InpATRMultiplier   = 2.0;   // SL = ATR × multiplier

// --- Advanced Trailing Stop ---
input bool   InpUseTrailing     = true;   // Aktifkan trailing stop bertahap
input double InpTrail1Trigger   = 30;     // Trigger level 1 (pips)
input double InpTrail1SL        = 10;     // SL di level 1 (lock 10 pips)
input double InpTrail2Trigger   = 60;     // Trigger level 2 (pips)
input double InpTrail2SL        = 35;     // SL di level 2 (lock 35 pips)
input double InpTrail3Trigger   = 100;    // Trigger level 3 (pips)
input double InpTrail3SL        = 70;     // SL di level 3 (lock 70 pips)
input double InpTrail4Trigger   = 200;    // Trigger level 4 (pips)
input double InpTrail4SL        = 150;    // SL di level 4 (lock 150 pips)

// --- Tiered TP (Partial Close) ---
input bool   InpUseTieredTP     = true;   // Aktifkan TP bertingkat
input double InpTP1R            = 1.0;    // TP1: close 50% di 1R
input double InpTP2R            = 2.0;    // TP2: close 25% di 2R
input double InpTP1ClosePct     = 50;     // Persentase close di TP1
input double InpTP2ClosePct     = 25;     // Persentase close di TP2

// --- Spread & Execution ---
input int InpMaxSpreadPoints = 80;
input bool InpIgnoreSpread = true;
input int InpSlippagePoints = 30;
input long InpMagicBase = 260601;
input bool InpAllowBuy = true;
input bool InpAllowSell = true;
input bool InpForexMetalsOnly = false;
input bool InpRequireMarketOpen = true;
input string InpBackendUrl = "http://127.0.0.1:8000/api/events/";
input bool InpDebugLog = true;
input bool InpLogSessionSkip = false;

CTrade trade;
string g_symbols[];
int g_symbol_count = 0;

enum SignalType
{
   SIGNAL_NONE = 0,
   SIGNAL_BUY = 1,
   SIGNAL_SELL = -1
};

// --- Global state ---
double g_dayStartBalance = 0.0;
datetime g_currentDay = 0;
bool g_tradingSuspended = false;

int OnInit()
{
   trade.SetDeviationInPoints(InpSlippagePoints);
   BuildSymbolList();

   if(g_symbol_count <= 0)
   {
      Print("No symbols available for scanning");
      return(INIT_FAILED);
   }

   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_currentDay = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   g_tradingSuspended = false;

   EventSetTimer(InpTimerSeconds);
   SendEvent("heartbeat", "", "", 0.0, 0.0, "", "EA v2 initialized");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   SendEvent("heartbeat", "", "", 0.0, 0.0, "", "EA deinitialized");
}

void OnTimer()
{
   SendEvent("heartbeat", "", "", 0.0, 0.0, "", "timer");

   // --- Reset daily balance tracking ---
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(today != g_currentDay)
   {
      g_currentDay = today;
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_tradingSuspended = false;
      if(InpDebugLog) Print("[DAILY RESET] balance=", DoubleToString(g_dayStartBalance, 2));
   }

   // --- Risk Management: cek max drawdown ---
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdownPct = (g_dayStartBalance > 0) ? (g_dayStartBalance - equity) / g_dayStartBalance * 100.0 : 0;
   if(InpMaxDrawdownPct > 0 && drawdownPct >= InpMaxDrawdownPct)
   {
      if(!g_tradingSuspended)
      {
         Print("[RISK] MAX DRAWDOWN tercapai: ", DoubleToString(drawdownPct, 1), "% >= ", DoubleToString(InpMaxDrawdownPct, 1), "% → trading PAUSED");
         g_tradingSuspended = true;
      }
      return;
   }

   // --- Risk Management: cek daily loss ---
   double dayPnl = AccountInfoDouble(ACCOUNT_PROFIT);
   double dailyLossPct = (g_dayStartBalance > 0) ? -dayPnl / g_dayStartBalance * 100.0 : 0;
   if(InpMaxDailyLossPct > 0 && dailyLossPct >= InpMaxDailyLossPct)
   {
      if(!g_tradingSuspended)
      {
         Print("[RISK] MAX DAILY LOSS tercapai: ", DoubleToString(dailyLossPct, 1), "% → trading STOP hari ini");
         g_tradingSuspended = true;
      }
      return;
   }

   // --- Risk Management: cek max open trades ---
   int openCount = CountOpenPositions();

   int signalCount = 0;
   for(int i = 0; i < g_symbol_count; i++)
   {
      string symbol = g_symbols[i];
      if(!SymbolInfoInteger(symbol, SYMBOL_SELECT))
         SymbolSelect(symbol, true);

      if(!IsEligibleSymbol(symbol))
         continue;

      if(!IsTradeSessionOpen(symbol))
      {
         if(InpLogSessionSkip) Print("[SKIP] ", symbol, ": sesi pasar tutup");
         continue;
      }

      // --- Tiered TP (partial close) ---
      if(InpUseTieredTP)
         ManageTieredTP(symbol);

      // --- Trailing stop ---
      if(InpUseTrailing)
         ManageTrailingStop(symbol);

      if(!InpIgnoreSpread && !IsSpreadAllowed(symbol))
      {
         if(InpDebugLog) Print("[SKIP] ", symbol, ": spread terlalu lebar");
         continue;
      }

      // --- Sinyal entry dari H4 ---
      SignalType signal = GetIchimokuSignal(symbol, InpTimeframe);
      if(signal == SIGNAL_NONE)
         continue;

      signalCount++;

      if(signal == SIGNAL_BUY && !InpAllowBuy)
      {
         Print("[SKIP] ", symbol, ": BUY tidak diizinkan");
         continue;
      }
      if(signal == SIGNAL_SELL && !InpAllowSell)
      {
         Print("[SKIP] ", symbol, ": SELL tidak diizinkan");
         continue;
      }

      if(HasOpenPosition(symbol, signal))
      {
         Print("[SKIP] ", symbol, ": posisi sudah ada");
         continue;
      }

      Print("[SIGNAL] ", symbol, ": ", (signal == SIGNAL_BUY ? "BUY" : "SELL"), " (", EnumToString(InpTimeframe), ")");
      CloseOppositePosition(symbol, signal);
      ExecuteOrder(symbol, signal);
      openCount++;
   }

   if(InpDebugLog)
      Print("[SCAN] simbol=", g_symbol_count, " sinyal=", signalCount, " open=", openCount,
         " equity=", DoubleToString(equity, 2), " dd=", DoubleToString(drawdownPct, 1), "%");
}

void BuildSymbolList()
{
   ArrayResize(g_symbols, 0);

   string inputSymbols = InpSymbols;
   StringTrimLeft(inputSymbols);
   StringTrimRight(inputSymbols);

   if(StringLen(inputSymbols) > 0)
   {
      // Mode manual: gunakan daftar simbol yang diketik di input
      string parts[];
      int count = StringSplit(inputSymbols, ',', parts);
      for(int i = 0; i < count; i++)
      {
         string s = parts[i];
         StringTrimLeft(s);
         StringTrimRight(s);
         if(StringLen(s) == 0)
            continue;
         SymbolSelect(s, true); // pastikan masuk Market Watch
         PushSymbol(s);
      }
   }
   else if(InpAllBrokerSymbols)
   {
      // Mode semua broker: ambil SELURUH simbol yang tersedia di server broker
      // SymbolsTotal(false) = semua simbol broker, bukan hanya Market Watch
      int total = SymbolsTotal(false);
      for(int i = 0; i < total; i++)
      {
         string s = SymbolName(i, false);
         if(StringLen(s) == 0)
            continue;
         // Tambahkan ke Market Watch agar data harga bisa diakses
         if(!SymbolInfoInteger(s, SYMBOL_SELECT))
            SymbolSelect(s, true);
         PushSymbol(s);
      }
   }
   else
   {
      // Mode Market Watch saja: hanya simbol yang sudah dipilih user
      int total = SymbolsTotal(true);
      for(int i = 0; i < total; i++)
      {
         string s = SymbolName(i, true);
         if(StringLen(s) == 0)
            continue;
         PushSymbol(s);
      }
   }

   g_symbol_count = ArraySize(g_symbols);
   Print("Symbol count: ", g_symbol_count,
         " (mode: ", (StringLen(inputSymbols) > 0 ? "manual" : (InpAllBrokerSymbols ? "all-broker" : "market-watch")), ")");
}

void PushSymbol(string symbol)
{
   for(int i = 0; i < ArraySize(g_symbols); i++)
   {
      if(g_symbols[i] == symbol)
         return;
   }

   int newSize = ArraySize(g_symbols) + 1;
   ArrayResize(g_symbols, newSize);
   g_symbols[newSize - 1] = symbol;
}

int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      // Hitung semua posisi dari EA ini
      if(magic >= InpMagicBase * 1000 && magic < (InpMagicBase + 1) * 1000)
         count++;
   }
   return count;
}

// Daftar mata uang forex ISO yang diizinkan (harus diperbarui bersama backend/trading/symbols.py)
bool IsKnownForexCurrency(string cur)
{
   return(cur == "USD" || cur == "EUR" || cur == "GBP" || cur == "JPY" ||
          cur == "CHF" || cur == "CAD" || cur == "AUD" || cur == "NZD" ||
          cur == "SEK" || cur == "NOK" || cur == "DKK" || cur == "SGD" ||
          cur == "HKD" || cur == "MXN" || cur == "ZAR" || cur == "TRY" ||
          cur == "PLN" || cur == "CZK" || cur == "HUF" || cur == "CNH");
}

bool IsEligibleSymbol(string symbol)
{
   // Cek dasar: pastikan symbol bisa di-trade (tidak di-disable broker)
   long tradeAllowed = SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   if(tradeAllowed == SYMBOL_TRADE_MODE_DISABLED)
      return(false);

   // Jika flag InpForexMetalsOnly=false, izinkan semua instrumen
   if(!InpForexMetalsOnly)
      return(true);

   // Jika InpForexMetalsOnly=true, batasi hanya ke forex + logam mulia
   string base = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
   string profit = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
   StringToUpper(base);
   StringToUpper(profit);

   // Logam mulia terhadap mata uang forex: XAUUSD, XAGUSD, XPTUSD, XPDUSD
   if((base == "XAU" || base == "XAG" || base == "XPT" || base == "XPD") &&
      IsKnownForexCurrency(profit))
      return(true);

   // Pasangan forex murni: kedua sisi harus mata uang ISO yang dikenal
   if(IsKnownForexCurrency(base) && IsKnownForexCurrency(profit) && base != profit)
      return(true);

   return(false);
}

bool IsTradeSessionOpen(string symbol)
{
   if(!InpRequireMarketOpen)
      return(true);

   long tradeMode = SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
      return(false);

   datetime now = TimeTradeServer();
   if(now <= 0)
      now = TimeCurrent();

   MqlDateTime dt;
   TimeToStruct(now, dt);
   int secNow = dt.hour * 3600 + dt.min * 60 + dt.sec;

   bool hasSession = false;
   for(int sessionIdx = 0; sessionIdx < 12; sessionIdx++)
   {
      datetime from = 0;
      datetime to = 0;
      if(!SymbolInfoSessionTrade(symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week, sessionIdx, from, to))
         break;

      hasSession = true;
      int fromSec = (int)from;
      int toSec = (int)to;

      if(fromSec <= toSec)
      {
         if(secNow >= fromSec && secNow < toSec)
            return(true);
      }
      else
      {
         if(secNow >= fromSec || secNow < toSec)
            return(true);
      }
   }

   // Some brokers do not provide session ranges; in that case keep original behavior.
   if(!hasSession)
      return(true);

   return(false);
}

bool IsSpreadAllowed(string symbol)
{
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0)
      return(false);

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0)
      return(false);

   double spreadPoints = (ask - bid) / point;
   return(spreadPoints <= InpMaxSpreadPoints);
}

// ---------------------------------------------------------------------------
// GetIchimokuSignal: semua kondisi Ichimoku pada satu TF (H4)
//   BUY:
//     1. Tenkan cross Kijun ke atas
//     2. Close di atas Kumo
//     3. Chikou di atas harga 26 bar lalu
//     4. Chikou tidak menabrak candle (di atas highest high 26 bar)
//     5. Chikou tidak menabrak Kumo (di atas cloud pada posisi 26 bar lalu)
//     6. SenkouA > SenkouB (current cloud bullish)
//     7. Future kumo bullish (SenkouA[2] > SenkouB[2])
//   SELL: kebalikan
// ---------------------------------------------------------------------------
SignalType GetIchimokuSignal(string symbol, ENUM_TIMEFRAMES tf)
{
   int handle = iIchimoku(symbol, tf, InpTenkan, InpKijun, InpSenkouB);
   if(handle == INVALID_HANDLE)
      return(SIGNAL_NONE);

   int    chikouBars = InpKijun + 2;
   double tenkan[3], kijun[3], senkouA[3], senkouB[3];
   double closePrice[];
   ArrayResize(closePrice, chikouBars);

   if(CopyBuffer(handle, 0, 0, 3, tenkan)              < 3          ||
      CopyBuffer(handle, 1, 0, 3, kijun)               < 3          ||
      CopyBuffer(handle, 2, 0, 3, senkouA)             < 3          ||
      CopyBuffer(handle, 3, 0, 3, senkouB)             < 3          ||
      CopyClose(symbol, tf, 0, chikouBars, closePrice) < chikouBars)
   {
      IndicatorRelease(handle);
      return(SIGNAL_NONE);
   }

   // Cloud pada posisi 26 bar lalu (untuk cek Chikou tidak menabrak Kumo)
   double senkouA_ref[1], senkouB_ref[1];
   bool cloudRefOk = (CopyBuffer(handle, 2, InpKijun + 1, 1, senkouA_ref) >= 1) &&
                      (CopyBuffer(handle, 3, InpKijun + 1, 1, senkouB_ref) >= 1);

   IndicatorRelease(handle);

   if(!cloudRefOk)
      return(SIGNAL_NONE);

   // --- Indeks array (non-AS_SERIES: terlama → terbaru) ---
   // tenkan/kijun/senkouA/senkouB : [0]=bar2, [1]=bar1(tutup), [2]=bar0(forming)
   // closePrice                   : [0]=bar(InpKijun+1), [InpKijun]=bar1, [InpKijun+1]=bar0

   double currentClose = closePrice[InpKijun];
   double chikouRef    = closePrice[0];

   double cloudTop    = MathMax(senkouA[1], senkouB[1]);
   double cloudBottom = MathMin(senkouA[1], senkouB[1]);

   // Cloud pada posisi 26 bar lalu
   double cloudTopRef    = MathMax(senkouA_ref[0], senkouB_ref[0]);
   double cloudBottomRef = MathMin(senkouA_ref[0], senkouB_ref[0]);

   // --- Cek Chikou terhadap candle 26 bar lalu ---
   // Chikou Span (close bar 1) harus di atas High candle 26 bar lalu (BUY)
   // atau di bawah Low candle 26 bar lalu (SELL)
   double highRef[], lowRef[];
   bool highRefOk = (CopyHigh(symbol, tf, InpKijun + 1, 1, highRef) >= 1);
   bool lowRefOk  = (CopyLow(symbol, tf, InpKijun + 1, 1, lowRef) >= 1);

   if(!highRefOk || !lowRefOk)
      return(SIGNAL_NONE);

   double chikouHighRef = highRef[0]; // High candle 26 bar lalu
   double chikouLowRef  = lowRef[0];  // Low candle 26 bar lalu

   // -----------------------------------------------------------------------
   // 7 KONDISI BUY (semua harus terpenuhi):
   //  1. TK cross ke atas (sudah terjadi, masih aktif)
   //     → sekarang tenkan > kijun, DAN di bar 1 atau 2 tenkan masih <= kijun
   //  2. Close di atas Kumo          : currentClose > cloudTop
   //  3. Chikou di atas harga lalu   : chikouNow > chikouRef
   //  4. Chikou di atas High 26 bar lalu : chikouNow > chikouHighRef
   //  5. Chikou tidak menabrak Kumo  : chikouNow > cloudTopRef
   //  6. Current Kumo bullish        : senkouA[1] > senkouB[1]
   //  7. Future Kumo bullish         : senkouA[2] > senkouB[2]
   // -----------------------------------------------------------------------
   // [0]=bar2, [1]=bar1(tutup), [2]=bar0(forming)
   bool b1 = tenkan[2] > kijun[2] && tenkan[1] > kijun[1] && tenkan[0] <= kijun[0];
   bool b2 = (currentClose > cloudTop);
    bool b3 = (currentClose > chikouRef);
    bool b4 = (currentClose > chikouHighRef);
    bool b5 = (currentClose > cloudTopRef);
   bool b6 = (senkouA[1] > senkouB[1]);
   bool b7 = (senkouA[2] > senkouB[2]);

   if(b1 && b2 && b3 && b4 && b5 && b6 && (!InpUseFutureKumoConfirm || b7))
   {
      if(InpDebugLog) Print("[ICHIMOKU BUY] ", symbol,
         " TK=", b1, " harga>cloud=", b2, " chikou>ref=", b3,
         " chikou>High26=", b4, " chikou>nokumo=", b5,
         " cloud=", b6, " future=", b7);
      return(SIGNAL_BUY);
   }

   // --- Near-miss log: tampilkan kondisi yang belum terpenuhi ---
   if(InpDebugLog)
   {
      int buyMet = (int)b1 + (int)b2 + (int)b3 + (int)b4 + (int)b5 + (int)b6 + (int)(!InpUseFutureKumoConfirm || b7);
      if(buyMet >= 5)
         Print("[NEAR-MISS BUY] ", symbol, " terpenuhi=", buyMet, "/7",
            " TK=", b1, " harga>cloud=", b2, " chikou>ref=", b3,
            " chikou>High26=", b4, " chikou>nokumo=", b5,
            " cloud=", b6, " future=", b7);
   }

   // -----------------------------------------------------------------------
   // 7 KONDISI SELL (semua harus terpenuhi):
   //  1. TK cross ke bawah (sudah terjadi, masih aktif)
   //     → sekarang tenkan < kijun, DAN di bar 1 atau 2 tenkan masih >= kijun
   //  2. Close di bawah Kumo          : currentClose < cloudBottom
   //  3. Chikou di bawah harga lalu   : chikouNow < chikouRef
   //  4. Chikou di bawah Low 26 bar lalu : chikouNow < chikouLowRef
   //  5. Chikou tidak menabrak Kumo   : chikouNow < cloudBottomRef
   //  6. Current Kumo bearish         : senkouA[1] < senkouB[1]
   //  7. Future Kumo bearish          : senkouA[2] < senkouB[2]
   // -----------------------------------------------------------------------
   bool s1 = tenkan[2] < kijun[2] && tenkan[1] < kijun[1] && tenkan[0] >= kijun[0];
   bool s2 = (currentClose < cloudBottom);
    bool s3 = (currentClose < chikouRef);
    bool s4 = (currentClose < chikouLowRef);
    bool s5 = (currentClose < cloudBottomRef);
   bool s6 = (senkouA[1] < senkouB[1]);
   bool s7 = (senkouA[2] < senkouB[2]);

   if(s1 && s2 && s3 && s4 && s5 && s6 && (!InpUseFutureKumoConfirm || s7))
   {
      if(InpDebugLog) Print("[ICHIMOKU SELL] ", symbol,
         " TK=", s1, " harga<cloud=", s2, " chikou<ref=", s3,
         " chikou<Low26=", s4, " chikou<nokumo=", s5,
         " cloud=", s6, " future=", s7);
      return(SIGNAL_SELL);
   }

   // --- Near-miss log ---
   if(InpDebugLog)
   {
      int sellMet = (int)s1 + (int)s2 + (int)s3 + (int)s4 + (int)s5 + (int)s6 + (int)(!InpUseFutureKumoConfirm || s7);
      if(sellMet >= 5)
         Print("[NEAR-MISS SELL] ", symbol, " terpenuhi=", sellMet, "/7",
            " TK=", s1, " harga<cloud=", s2, " chikou<ref=", s3,
            " chikou<Low26=", s4, " chikou<nokumo=", s5,
            " cloud=", s6, " future=", s7);
   }

   return(SIGNAL_NONE);
}

long BuildMagic(string symbol)
{
   int hash = 0;
   for(int i = 0; i < StringLen(symbol); i++)
      hash += StringGetCharacter(symbol, i);

   return(InpMagicBase * 1000 + hash);
}

bool HasOpenPosition(string symbol, SignalType signal)
{
   long magic = BuildMagic(symbol);
   int total = PositionsTotal();

   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string posSymbol = PositionGetString(POSITION_SYMBOL);
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      long type = PositionGetInteger(POSITION_TYPE);

      if(posSymbol != symbol || posMagic != magic)
         continue;

      if(signal == SIGNAL_BUY && type == POSITION_TYPE_BUY)
         return(true);
      if(signal == SIGNAL_SELL && type == POSITION_TYPE_SELL)
         return(true);
   }

   return(false);
}

// Tutup posisi BUY saat TK cross bearish, tutup posisi SELL saat TK cross bullish
void CloseTKExit(string symbol)
{
   long magic = BuildMagic(symbol);
   int total = PositionsTotal();

   // Periksa apakah ada posisi terbuka untuk simbol ini
   bool hasBuy = false, hasSell = false;
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY)  hasBuy  = true;
      if(type == POSITION_TYPE_SELL) hasSell = true;
   }
   if(!hasBuy && !hasSell) return;

   // Ambil data Ichimoku (TF entry)
   int handle = iIchimoku(symbol, InpTimeframe, InpTenkan, InpKijun, InpSenkouB);
   if(handle == INVALID_HANDLE) return;

   double tenkan[3], kijun[3];
   if(CopyBuffer(handle, 0, 0, 3, tenkan) < 3 ||
      CopyBuffer(handle, 1, 0, 3, kijun)  < 3)
   {
      IndicatorRelease(handle);
      return;
   }
   IndicatorRelease(handle);

   // [0]=bar2 (2 bar lalu), [1]=bar1 (bar terakhir tutup)
   // Bearish TK cross: exit BUY  → tenkan turun melewati kijun
   bool bearishCross = (tenkan[0] >= kijun[0]) && (tenkan[1] < kijun[1]);
   // Bullish TK cross: exit SELL → tenkan naik melewati kijun
   bool bullishCross = (tenkan[0] <= kijun[0]) && (tenkan[1] > kijun[1]);

   if(!bearishCross && !bullishCross) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      long   type  = PositionGetInteger(POSITION_TYPE);
      double vol   = PositionGetDouble(POSITION_VOLUME);
      double price = PositionGetDouble(POSITION_PRICE_CURRENT);

      if(bearishCross && type == POSITION_TYPE_BUY)
      {
         if(trade.PositionClose(ticket))
         {
            if(InpDebugLog) Print("[TK EXIT BUY] ", symbol, " tiket=", ticket, " TK bearish cross → TP");
            SendEvent("trade_close", symbol, "BUY", vol, price, StringFormat("%I64u", ticket), "tk_cross_exit");
         }
      }

      if(bullishCross && type == POSITION_TYPE_SELL)
      {
         if(trade.PositionClose(ticket))
         {
            if(InpDebugLog) Print("[TK EXIT SELL] ", symbol, " tiket=", ticket, " TK bullish cross → TP");
            SendEvent("trade_close", symbol, "SELL", vol, price, StringFormat("%I64u", ticket), "tk_cross_exit");
         }
      }
   }
}

// ---------------------------------------------------------------------------
// ManageTieredTP: TP bertingkat (partial close)
//   TP1: harga capai 1R → close 50%, SL geser ke BE
//   TP2: harga capai 2R → close 25%, SL geser ke 1R
//   Sisa 25% trailing sampai TK cross exit
// Risk = |entry - SL|, R:R diukur dari risk tersebut
// ---------------------------------------------------------------------------
void ManageTieredTP(string symbol)
{
   if(!InpUseTieredTP)
      return;

   long magic = BuildMagic(symbol);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0) return;

   long digits = SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      long   type      = PositionGetInteger(POSITION_TYPE);
      double entry     = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double vol       = PositionGetDouble(POSITION_VOLUME);
      double bid       = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask       = SymbolInfoDouble(symbol, SYMBOL_ASK);

      if(type == POSITION_TYPE_BUY)
      {
          double risk = entry - currentSL;
          if(risk <= 0) continue;
          if(risk < point * 20) continue; // SL terlalu dekat (trailing sudah geser), skip tiered TP

         double tp1Level = entry + risk * InpTP1R;
         double tp2Level = entry + risk * InpTP2R;

         // TP2: close 25% di 2R
         if(ask >= tp2Level && vol > InpMinLotSize * 1.5)
         {
            double closeLot = NormalizeDouble(vol * InpTP2ClosePct / 100.0, 2);
            double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
            if(lotStep > 0) closeLot = MathFloor(closeLot / lotStep) * lotStep;
            closeLot = MathMax(closeLot, InpMinLotSize);

            if(closeLot < vol)
            {
               if(trade.PositionClosePartial(ticket, closeLot))
               {
                  if(InpDebugLog) Print("[TP2 BUY] ", symbol, " tiket=", ticket,
                     " close ", DoubleToString(closeLot, 2), " lot di ", DoubleToString(ask, (int)digits),
                     " (2R=", DoubleToString(tp2Level, (int)digits), ")");

                  // Geser SL ke 1R setelah TP2
                  double newSL = NormalizeDouble(entry + risk, (int)digits);
                  if(newSL > currentSL)
                  {
                     PositionSelectByTicket(ticket); // reselect setelah partial close
                     trade.PositionModify(ticket, newSL, currentTP);
                  }
               }
            }
         }
         // TP1: close 50% di 1R (hanya jika TP2 belum tercapai)
         else if(ask >= tp1Level && vol > InpMinLotSize * 1.8)
         {
            double closeLot = NormalizeDouble(vol * InpTP1ClosePct / 100.0, 2);
            double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
            if(lotStep > 0) closeLot = MathFloor(closeLot / lotStep) * lotStep;
            closeLot = MathMax(closeLot, InpMinLotSize);

            if(closeLot < vol)
            {
               if(trade.PositionClosePartial(ticket, closeLot))
               {
                  if(InpDebugLog) Print("[TP1 BUY] ", symbol, " tiket=", ticket,
                     " close ", DoubleToString(closeLot, 2), " lot di ", DoubleToString(ask, (int)digits),
                     " (1R=", DoubleToString(tp1Level, (int)digits), ")");

                  // Geser SL ke BE setelah TP1
                  double newSL = NormalizeDouble(entry + point * 10, (int)digits); // BE + buffer
                  if(newSL > currentSL)
                  {
                     PositionSelectByTicket(ticket);
                     trade.PositionModify(ticket, newSL, currentTP);
                  }
               }
            }
         }
      }

      if(type == POSITION_TYPE_SELL)
      {
          double risk = currentSL - entry;
          if(risk <= 0) continue;
          if(risk < point * 20) continue; // SL terlalu dekat (trailing sudah geser), skip tiered TP

         double tp1Level = entry - risk * InpTP1R;
         double tp2Level = entry - risk * InpTP2R;

         // TP2: close 25% di 2R
         if(bid <= tp2Level && vol > InpMinLotSize * 1.5)
         {
            double closeLot = NormalizeDouble(vol * InpTP2ClosePct / 100.0, 2);
            double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
            if(lotStep > 0) closeLot = MathFloor(closeLot / lotStep) * lotStep;
            closeLot = MathMax(closeLot, InpMinLotSize);

            if(closeLot < vol)
            {
               if(trade.PositionClosePartial(ticket, closeLot))
               {
                  if(InpDebugLog) Print("[TP2 SELL] ", symbol, " tiket=", ticket,
                     " close ", DoubleToString(closeLot, 2), " lot di ", DoubleToString(bid, (int)digits),
                     " (2R=", DoubleToString(tp2Level, (int)digits), ")");

                  double newSL = NormalizeDouble(entry - risk, (int)digits);
                  if(newSL < currentSL)
                  {
                     PositionSelectByTicket(ticket);
                     trade.PositionModify(ticket, newSL, currentTP);
                  }
               }
            }
         }
         // TP1: close 50% di 1R
         else if(bid <= tp1Level && vol > InpMinLotSize * 1.8)
         {
            double closeLot = NormalizeDouble(vol * InpTP1ClosePct / 100.0, 2);
            double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
            if(lotStep > 0) closeLot = MathFloor(closeLot / lotStep) * lotStep;
            closeLot = MathMax(closeLot, InpMinLotSize);

            if(closeLot < vol)
            {
               if(trade.PositionClosePartial(ticket, closeLot))
               {
                  if(InpDebugLog) Print("[TP1 SELL] ", symbol, " tiket=", ticket,
                     " close ", DoubleToString(closeLot, 2), " lot di ", DoubleToString(bid, (int)digits),
                     " (1R=", DoubleToString(tp1Level, (int)digits), ")");

                  double newSL = NormalizeDouble(entry - point * 10, (int)digits);
                  if(newSL < currentSL)
                  {
                     PositionSelectByTicket(ticket);
                     trade.PositionModify(ticket, newSL, currentTP);
                  }
               }
            }
         }
      }
   }
}

// ---------------------------------------------------------------------------
// ManageTrailingStop: trailing stop bertahap
//   Level 1: profit >= 30 pips → SL ke entry + 10 pips (lock 10)
//   Level 2: profit >= 60 pips → SL ke entry + 35 pips (lock 35)
//   Level 3: profit >= 100 pips → SL ke entry + 70 pips (lock 70)
//   Level 4: profit >= 200 pips → SL ke entry + 150 pips (lock 150)
// SL hanya digeser searah profit — tidak pernah mundur
// ---------------------------------------------------------------------------
void ManageTrailingStop(string symbol)
{
   long magic = BuildMagic(symbol);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0) return;

   long digits = SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      long   type      = PositionGetInteger(POSITION_TYPE);
      double entry     = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double bid       = SymbolInfoDouble(symbol, SYMBOL_BID);
      double ask       = SymbolInfoDouble(symbol, SYMBOL_ASK);

      double newSL = 0.0;
      bool shouldModify = false;

      if(type == POSITION_TYPE_BUY)
      {
         double profitPips = (ask - entry) / point;

         // Cek level dari yang tertinggi ke terendah
         if(InpUseTrailing && profitPips >= InpTrail4Trigger)
         {
            double desired = NormalizeDouble(entry + InpTrail4SL * point, (int)digits);
            if(desired > currentSL) { newSL = desired; shouldModify = true; }
         }
         else if(InpUseTrailing && profitPips >= InpTrail3Trigger)
         {
            double desired = NormalizeDouble(entry + InpTrail3SL * point, (int)digits);
            if(desired > currentSL) { newSL = desired; shouldModify = true; }
         }
         else if(InpUseTrailing && profitPips >= InpTrail2Trigger)
         {
            double desired = NormalizeDouble(entry + InpTrail2SL * point, (int)digits);
            if(desired > currentSL) { newSL = desired; shouldModify = true; }
         }
         else if(InpUseTrailing && profitPips >= InpTrail1Trigger)
         {
            double desired = NormalizeDouble(entry + InpTrail1SL * point, (int)digits);
            if(desired > currentSL) { newSL = desired; shouldModify = true; }
         }
      }

      if(type == POSITION_TYPE_SELL)
      {
         double profitPips = (entry - bid) / point;

         if(InpUseTrailing && profitPips >= InpTrail4Trigger)
         {
            double desired = NormalizeDouble(entry - InpTrail4SL * point, (int)digits);
            if(desired < currentSL || currentSL == 0) { newSL = desired; shouldModify = true; }
         }
         else if(InpUseTrailing && profitPips >= InpTrail3Trigger)
         {
            double desired = NormalizeDouble(entry - InpTrail3SL * point, (int)digits);
            if(desired < currentSL || currentSL == 0) { newSL = desired; shouldModify = true; }
         }
         else if(InpUseTrailing && profitPips >= InpTrail2Trigger)
         {
            double desired = NormalizeDouble(entry - InpTrail2SL * point, (int)digits);
            if(desired < currentSL || currentSL == 0) { newSL = desired; shouldModify = true; }
         }
         else if(InpUseTrailing && profitPips >= InpTrail1Trigger)
         {
            double desired = NormalizeDouble(entry - InpTrail1SL * point, (int)digits);
            if(desired < currentSL || currentSL == 0) { newSL = desired; shouldModify = true; }
         }
      }

      if(shouldModify)
      {
         if(trade.PositionModify(ticket, newSL, currentTP))
         {
            if(InpDebugLog) Print("[TRAILING] ", symbol, " tiket=", ticket,
               " SL: ", DoubleToString(currentSL, (int)digits), " → ", DoubleToString(newSL, (int)digits));
         }
      }
   }
}

void CloseOppositePosition(string symbol, SignalType signal)
{
   long magic = BuildMagic(symbol);
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string posSymbol = PositionGetString(POSITION_SYMBOL);
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      long type = PositionGetInteger(POSITION_TYPE);

      if(posSymbol != symbol || posMagic != magic)
         continue;

      if(signal == SIGNAL_BUY && type == POSITION_TYPE_SELL)
      {
         if(trade.PositionClose(ticket))
            SendEvent("trade_close", symbol, "SELL", PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_CURRENT), StringFormat("%I64u", ticket), "reverse to buy");
      }

      if(signal == SIGNAL_SELL && type == POSITION_TYPE_BUY)
      {
         if(trade.PositionClose(ticket))
            SendEvent("trade_close", symbol, "BUY", PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_CURRENT), StringFormat("%I64u", ticket), "reverse to sell");
      }
   }
}

void ExecuteOrder(string symbol, SignalType signal)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0)
      return;

   long digits = SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   long magic = BuildMagic(symbol);
   trade.SetExpertMagicNumber(magic);

   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double sl = 0.0;
   double tp = 0.0;
   bool result = false;

   // --- Hitung SL distance ---
   long   minStopPts = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long   freezePts  = SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long   stopLevel  = MathMax(minStopPts, freezePts);
   double minStopDist = (stopLevel + 10) * point;

   double slDistance = minStopDist;

   // ATR-based SL (prioritas jika aktif)
   if(InpUseATRSL)
   {
      int atrHandle = iATR(symbol, InpTimeframe, InpATRPeriod);
      if(atrHandle != INVALID_HANDLE)
      {
         double atrVal[];
         if(CopyBuffer(atrHandle, 0, 0, 1, atrVal) >= 1)
         {
            slDistance = atrVal[0] * InpATRMultiplier;
         }
         IndicatorRelease(atrHandle);
      }
   }

   slDistance = MathMax(slDistance, minStopDist);

   if(InpDebugLog) Print("[EXECUTE] ", symbol,
      " point=", DoubleToString(point, digits),
      " digits=", digits,
      " minStopDist=", DoubleToString(minStopDist, (int)digits),
      " slDistance=", DoubleToString(slDistance, (int)digits));

   // --- Hitung lot berdasarkan risk % ---
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;
   double tickValue  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);

   double lot = InpMinLotSize;
   if(tickValue > 0 && tickSize > 0 && slDistance > 0)
   {
      double slTicks = slDistance / tickSize;
      lot = riskAmount / (slTicks * tickValue);
      lot = MathMax(lot, InpMinLotSize);
      lot = MathMin(lot, InpMaxLotSize);

      // Normalize ke step volume
      double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      if(lotStep > 0)
         lot = MathFloor(lot / lotStep) * lotStep;
      lot = NormalizeDouble(lot, 2);
   }

   if(signal == SIGNAL_BUY)
   {
      sl = NormalizeDouble(ask - slDistance, (int)digits);
      tp = 0.0;

      if(InpDebugLog) Print("[ORDER] BUY ", symbol,
         " ask=", DoubleToString(ask, (int)digits),
         " sl=", DoubleToString(sl, (int)digits),
         " dist=", DoubleToString(slDistance, (int)digits),
         " lot=", DoubleToString(lot, 2),
         " risk=", DoubleToString(riskAmount, 2));

      string msgBuy = "ichimoku buy | tf:" + EnumToString(InpTimeframe)
                       + " lot=" + DoubleToString(lot, 2) + " sl_atr=" + DoubleToString(slDistance, (int)digits);
      SendEvent("signal", symbol, "BUY", lot, ask, "", msgBuy);
      result = trade.Buy(lot, symbol, ask, sl, tp, "Ichimoku BUY");
   }

   if(signal == SIGNAL_SELL)
   {
      sl = NormalizeDouble(bid + slDistance, (int)digits);
      tp = 0.0;

      if(InpDebugLog) Print("[ORDER] SELL ", symbol,
         " bid=", DoubleToString(bid, (int)digits),
         " sl=", DoubleToString(sl, (int)digits),
         " dist=", DoubleToString(slDistance, (int)digits),
         " lot=", DoubleToString(lot, 2),
         " risk=", DoubleToString(riskAmount, 2));

      string msgSell = "ichimoku sell | tf:" + EnumToString(InpTimeframe)
                        + " lot=" + DoubleToString(lot, 2) + " sl_atr=" + DoubleToString(slDistance, (int)digits);
      SendEvent("signal", symbol, "SELL", lot, bid, "", msgSell);
      result = trade.Sell(lot, symbol, bid, sl, tp, "Ichimoku SELL");
   }

   if(result)
   {
      ulong ticket = trade.ResultOrder();
      double price = trade.ResultPrice();
      string ticketStr = StringFormat("%I64u", ticket);
      if(signal == SIGNAL_BUY)
         SendEvent("trade_open", symbol, "BUY", lot, price, ticketStr, "opened", sl, tp);
      if(signal == SIGNAL_SELL)
         SendEvent("trade_open", symbol, "SELL", lot, price, ticketStr, "opened", sl, tp);
   }
   else
   {
      string msg = StringFormat("Trade failed. Retcode=%d (%s)", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      SendEvent("error", symbol, (signal == SIGNAL_BUY ? "BUY" : "SELL"), lot, 0.0, "", msg);
   }
}

void SendEvent(string eventType, string symbol, string side, double volume, double price, string ticket, string message, double sl = 0.0, double tp = 0.0)
{
   string payload = StringFormat(
      "{\"event_type\":\"%s\",\"symbol\":\"%s\",\"side\":\"%s\",\"volume\":%.2f,\"price\":%.5f,\"ticket\":\"%s\",\"message\":\"%s\",\"sl\":%.5f,\"tp\":%.5f}",
      eventType,
      symbol,
      side,
      volume,
      price,
      ticket,
      EscapeJson(message),
      sl,
      tp
   );

   char postData[];
   char result[];
   string headers = "Content-Type: application/json\r\n";
   // StringToCharArray menyertakan null-terminator; potong agar POST body bersih
   int byteCount = StringToCharArray(payload, postData, 0, WHOLE_ARRAY, CP_UTF8);
   if(byteCount > 1) ArrayResize(postData, byteCount - 1);

   string responseHeaders;
   int timeout = 5000;
   int res = WebRequest("POST", InpBackendUrl, headers, timeout, postData, result, responseHeaders);

   if(res == -1)
      Print("WebRequest failed (error ", GetLastError(), ") - pastikan URL diizinkan di MT5 Options > Expert Advisors");
   else if(res != 200)
      Print("WebRequest HTTP ", res, " untuk ", InpBackendUrl);
}

string EscapeJson(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   return(s);
}
