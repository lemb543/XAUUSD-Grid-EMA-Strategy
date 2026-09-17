//+------------------------------------------------------------------+
//| XAUUSDm_EMA_Grid_Hedge_Bot.mq5                                  |
//| Safer hedge-grid cycle for XAUUSDm                               |
//|                                                                  |
//| Rules:                                                           |
//| 1. XAUUSDm only, M1 EMA(10).                                    |
//| 2. At each new 50-point grid level, open one BUY and one SELL.   |
//| 3. The EMA is used as a gate: price above EMA10 = buy bias;      |
//|    price below EMA10 = sell bias. Both hedge orders are still    |
//|    opened together because the requested strategy is a hedge.    |
//| 4. Close this EA's XAUUSDm positions when combined profit reaches |
//|    the target, then open the next hedge pair after closure.      |
//| 5. If either leg of a pair fails, close the successful leg so the |
//|    EA does not leave an unintended one-sided trade.              |
//|                                                                  |
//| IMPORTANT: Hedging mode is required to hold BUY and SELL         |
//| positions simultaneously. Test on demo first.                   |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"

#include <Trade/Trade.mqh>

input double InpLotSize          = 0.01;       // Lot size per leg
input int    InpGridPoints       = 50;         // Grid spacing in points
input int    InpEMAPeriod        = 10;         // EMA period
input double InpProfitTargetUSD  = 5.00;       // Combined profit target
input ulong  InpMagicNumber      = 20260917;   // EA magic number
input int    InpDeviationPoints  = 20;         // Maximum slippage
input bool   InpOpenInitialPair  = true;       // Open first pair at nearest grid

const string TRADE_SYMBOL = "XAUUSDm";
const ENUM_TIMEFRAMES TRADE_TIMEFRAME = PERIOD_M1;

CTrade g_trade;
int    g_emaHandle = INVALID_HANDLE;
double g_gridStep = 0.0;
double g_lastOpenedGrid = 0.0;
bool   g_haveOpenedGrid = false;
bool   g_reopenAfterClose = false;

//+------------------------------------------------------------------+
int OnInit()
{
   if(Symbol() != TRADE_SYMBOL)
   {
      Alert("Attach this EA to XAUUSDm only. Current chart: ", Symbol());
      return INIT_FAILED;
   }

   if(!SymbolSelect(TRADE_SYMBOL, true))
   {
      Alert("XAUUSDm is not available in Market Watch.");
      return INIT_FAILED;
   }

   long tradeMode = SymbolInfoInteger(TRADE_SYMBOL, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
   {
      Alert("Trading is disabled for XAUUSDm.");
      return INIT_FAILED;
   }

   ENUM_ACCOUNT_MARGIN_MODE marginMode =
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Alert("This strategy requires a hedging MT5 account; netting accounts cannot hold both legs.");
      return INIT_FAILED;
   }

   double point = SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_POINT);
   g_gridStep = InpGridPoints * point;
   if(point <= 0.0 || g_gridStep <= 0.0)
   {
      Alert("Invalid XAUUSDm point or grid size.");
      return INIT_FAILED;
   }

   g_emaHandle = iMA(TRADE_SYMBOL, TRADE_TIMEFRAME, InpEMAPeriod,
                     0, MODE_EMA, PRICE_CLOSE);
   if(g_emaHandle == INVALID_HANDLE)
   {
      Alert("Could not create EMA10 handle for XAUUSDm M1.");
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(TRADE_SYMBOL);

   Print("XAUUSDm EMA Grid Hedge Bot initialized. Grid=", g_gridStep,
         ", lot per leg=", InpLotSize, ", target=$", InpProfitTargetUSD);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_emaHandle != INVALID_HANDLE)
      IndicatorRelease(g_emaHandle);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(Symbol() != TRADE_SYMBOL)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(TRADE_SYMBOL, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
      return;

   double ema = GetEMA();
   if(ema <= 0.0)
      return;

   int ownPositions = CountOwnPositions();
   double totalProfit = GetOwnProfit();

   // Close only this EA's positions when combined profit reaches target.
   if(ownPositions > 0 && totalProfit >= InpProfitTargetUSD)
   {
      if(CloseOwnPositions())
      {
         g_reopenAfterClose = true;
         Print("Profit target reached: $", DoubleToString(totalProfit, 2),
               ". Positions closed; a new pair will be opened when flat.");
      }
      return;
   }

   // Never add to an existing cycle.
   if(CountOwnPositions() > 0)
      return;

   double mid = (tick.bid + tick.ask) / 2.0;
   double gridLevel = GridLevel(mid);

   // After a profitable close, reopen immediately at the current grid level.
   if(g_reopenAfterClose)
   {
      if(OpenHedgePair(gridLevel, mid, ema))
         g_reopenAfterClose = false;
      return;
   }

   // First pair: optional, at the nearest grid level.
   if(!g_haveOpenedGrid && InpOpenInitialPair)
   {
      if(OpenHedgePair(gridLevel, mid, ema))
      {
         g_lastOpenedGrid = gridLevel;
         g_haveOpenedGrid = true;
      }
      return;
   }

   // Open only once when price reaches a different 50-point grid level.
   if(g_haveOpenedGrid && !SamePrice(gridLevel, g_lastOpenedGrid))
   {
      if(OpenHedgePair(gridLevel, mid, ema))
         g_lastOpenedGrid = gridLevel;
   }
}

//+------------------------------------------------------------------+
//| Open both legs as an atomic-enough operation.                    |
//+------------------------------------------------------------------+
bool OpenHedgePair(const double gridLevel, const double mid, const double ema)
{
   bool buyBias = (mid > ema);
   bool sellBias = (mid < ema);
   if(!buyBias && !sellBias)
      return false; // price exactly equal to EMA: wait for a clear bias

   string bias = buyBias ? "BUY" : "SELL";
   bool buyOK = g_trade.Buy(InpLotSize, TRADE_SYMBOL, 0.0, 0.0, 0.0,
                            "EMA_GRID_BUY");
   ulong buyTicket = g_trade.ResultOrder();

   bool sellOK = g_trade.Sell(InpLotSize, TRADE_SYMBOL, 0.0, 0.0, 0.0,
                              "EMA_GRID_SELL");
   ulong sellTicket = g_trade.ResultOrder();

   if(!buyOK || !sellOK)
   {
      Print("Hedge pair incomplete at grid ", gridLevel,
            ". BUY=", buyOK, ", SELL=", sellOK,
            ", retcode=", g_trade.ResultRetcode(),
            ", comment=", g_trade.ResultRetcodeDescription());

      // Do not leave a one-sided position if one leg failed.
      if(buyOK && buyTicket > 0)
         g_trade.PositionClose(buyTicket);
      if(sellOK && sellTicket > 0)
         g_trade.PositionClose(sellTicket);
      return false;
   }

   Print("Hedge pair opened at grid ", gridLevel,
         ". EMA bias=", bias, ", BUY ticket=", buyTicket,
         ", SELL ticket=", sellTicket);
   return true;
}

//+------------------------------------------------------------------+
int CountOwnPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) == TRADE_SYMBOL &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
double GetOwnProfit()
{
   double profit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != TRADE_SYMBOL ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      profit += PositionGetDouble(POSITION_PROFIT);
      profit += PositionGetDouble(POSITION_SWAP);
   }
   return profit;
}

//+------------------------------------------------------------------+
bool CloseOwnPositions()
{
   bool allRequestsAccepted = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != TRADE_SYMBOL ||
         (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      if(!g_trade.PositionClose(ticket))
      {
         allRequestsAccepted = false;
         Print("Close failed for ticket ", ticket, ": ",
               g_trade.ResultRetcodeDescription());
      }
   }
   return allRequestsAccepted && CountOwnPositions() == 0;
}

//+------------------------------------------------------------------+
double GetEMA()
{
   double buffer[];
   ArraySetAsSeries(buffer, true);
   if(CopyBuffer(g_emaHandle, 0, 0, 1, buffer) != 1)
      return 0.0;
   return buffer[0];
}

//+------------------------------------------------------------------+
double GridLevel(const double price)
{
   return NormalizeDouble(MathFloor(price / g_gridStep) * g_gridStep,
                          (int)SymbolInfoInteger(TRADE_SYMBOL, SYMBOL_DIGITS));
}

//+------------------------------------------------------------------+
bool SamePrice(const double first, const double second)
{
   return MathAbs(first - second) <= (SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_POINT) / 2.0);
}
//+------------------------------------------------------------------+
