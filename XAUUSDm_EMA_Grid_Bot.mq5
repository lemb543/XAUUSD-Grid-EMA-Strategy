//+------------------------------------------------------------------+
//| XAUUSDm_EMA_Grid_Bot.mq5                                         |
//| Corrected strategy for XAUUSDm                                    |
//|                                                                  |
//| Cycle structure:                                                 |
//| 1. At cycle start open BUY + SELL simultaneously (0.01 each).     |
//| 2. Then on each new 1-point grid, if price > EMA10 open BUY only |
//|    and if price < EMA10 open SELL only.                           |
//| 3. When total EA profit >= $5, close all positions and start a    |
//|    new cycle.                                                    |
//| 4. Pair: XAUUSDm, M1, EMA10                                      |
//| 5. Requires hedging MT5 account.                                 |
//+------------------------------------------------------------------+
#property strict
#property version "1.04"

#include <Trade/Trade.mqh>

input double InpLotSize          = 0.01;       // lot size per order
input int    InpGridPoints       = 1;          // grid spacing in points
input int    InpEMAPeriod        = 10;         // EMA period
input double InpProfitTargetUSD  = 5.00;       // total profit target in USD
input ulong  InpMagicNumber      = 20260917;   // unique magic number
input int    InpDeviationPoints  = 20;         // max slippage in points
input int    InpMaxOrders        = 100;        // maximum orders safety cap

const string TRADE_SYMBOL = "XAUUSDm";
const ENUM_TIMEFRAMES TRADE_TIMEFRAME = PERIOD_M1;

CTrade g_trade;
int    g_emaHandle = INVALID_HANDLE;
double g_gridStep = 0.0;
double g_lastGridLevel = 0.0;
bool   g_cycleStarted = false;

//+------------------------------------------------------------------+
//| Expert initialization                                             |
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
      Alert("This strategy requires a hedging MT5 account. Netting accounts cannot hold BUY and SELL simultaneously.");
      return INIT_FAILED;
   }

   double point = SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_POINT);
   g_gridStep = InpGridPoints * point;

   if(point <= 0.0 || g_gridStep <= 0.0)
   {
      Alert("Invalid XAUUSDm point size or grid step.");
      return INIT_FAILED;
   }

   g_emaHandle = iMA(
      TRADE_SYMBOL,
      TRADE_TIMEFRAME,
      InpEMAPeriod,
      0,
      MODE_EMA,
      PRICE_CLOSE
   );

   if(g_emaHandle == INVALID_HANDLE)
   {
      Alert("Could not create EMA10 indicator for XAUUSDm M1.");
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(TRADE_SYMBOL);

   Print("==============================================");
   Print("XAUUSDm EMA Grid Bot initialized");
   Print("Symbol: ", TRADE_SYMBOL);
   Print("Timeframe: M1");
   Print("EMA period: ", InpEMAPeriod);
   Print("Grid spacing: ", InpGridPoints, " point(s)");
   Print("Grid distance: ", DoubleToString(g_gridStep, 5));
   Print("Lot per order: ", DoubleToString(InpLotSize, 2));
   Print("Target: $", DoubleToString(InpProfitTargetUSD, 2));
   Print("==============================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_emaHandle != INVALID_HANDLE)
      IndicatorRelease(g_emaHandle);
}

//+------------------------------------------------------------------+
//| Expert tick                                                       |
//+------------------------------------------------------------------+
void OnTick()
{
   if(Symbol() != TRADE_SYMBOL)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(TRADE_SYMBOL, tick))
      return;

   if(tick.bid <= 0.0 || tick.ask <= 0.0)
      return;

   double ema = GetEMA();
   if(ema <= 0.0)
      return;

   double currentPrice = (tick.bid + tick.ask) / 2.0;
   double currentGrid = GridLevel(currentPrice);

   double totalProfit = GetOwnProfit();

   // Close all when target reached.
   if(totalProfit >= InpProfitTargetUSD)
   {
      if(CloseAllPositions())
      {
         g_cycleStarted = false;
         g_lastGridLevel = 0.0;
         Print("Target hit. All positions closed. New cycle will start next tick.");
      }
      return;
   }

   // If cycle not started, open BUY and SELL simultaneously.
   if(!g_cycleStarted)
   {
      if(OpenInitialHedgePair())
      {
         g_cycleStarted = true;
         g_lastGridLevel = currentGrid;
      }
      return;
   }

   // If new grid level is reached, open only one directional order.
   if(!SamePrice(currentGrid, g_lastGridLevel))
   {
      if(currentPrice > ema)
      {
         if(OpenBuyOnly())
            g_lastGridLevel = currentGrid;
      }
      else if(currentPrice < ema)
      {
         if(OpenSellOnly())
            g_lastGridLevel = currentGrid;
      }
   }
}

//+------------------------------------------------------------------+
//| Start cycle: open BUY + SELL simultaneously                        |
//+------------------------------------------------------------------+
bool OpenInitialHedgePair()
{
   bool buyOK = g_trade.Buy(
      InpLotSize,
      TRADE_SYMBOL,
      0.0,
      0.0,
      0.0,
      "INIT_BUY"
   );

   ulong buyTicket = g_trade.ResultOrder();

   bool sellOK = g_trade.Sell(
      InpLotSize,
      TRADE_SYMBOL,
      0.0,
      0.0,
      0.0,
      "INIT_SELL"
   );

   ulong sellTicket = g_trade.ResultOrder();

   if(!buyOK || !sellOK)
   {
      Print("Initial hedge pair failed. BUY=", buyOK, " SELL=", sellOK,
            " retcode=", g_trade.ResultRetcode(),
            " comment=", g_trade.ResultRetcodeDescription());

      if(buyOK && buyTicket > 0)
         ClosePositionByTicket(buyTicket);

      if(sellOK && sellTicket > 0)
         ClosePositionByTicket(sellTicket);

      return false;
   }

   Print("Initial hedge pair opened: BUY + SELL 0.01 lot each.");
   return true;
}

//+------------------------------------------------------------------+
//| Open only BUY at the new grid level                               |
//+------------------------------------------------------------------+
bool OpenBuyOnly()
{
   if(GetOwnOrderCount() >= InpMaxOrders)
      return false;

   bool ok = g_trade.Buy(
      InpLotSize,
      TRADE_SYMBOL,
      0.0,
      0.0,
      0.0,
      "GRID_BUY"
   );

   if(ok)
      Print("BUY order opened at grid ", DoubleToString(g_lastGridLevel, 5));
   else
      Print("BUY order failed: ", g_trade.ResultRetcodeDescription());

   return ok;
}

//+------------------------------------------------------------------+
//| Open only SELL at the new grid level                              |
//+------------------------------------------------------------------+
bool OpenSellOnly()
{
   if(GetOwnOrderCount() >= InpMaxOrders)
      return false;

   bool ok = g_trade.Sell(
      InpLotSize,
      TRADE_SYMBOL,
      0.0,
      0.0,
      0.0,
      "GRID_SELL"
   );

   if(ok)
      Print("SELL order opened at grid ", DoubleToString(g_lastGridLevel, 5));
   else
      Print("SELL order failed: ", g_trade.ResultRetcodeDescription());

   return ok;
}

//+------------------------------------------------------------------+
//| Count all positions owned by this EA                              |
//+------------------------------------------------------------------+
int GetOwnOrderCount()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);

      if(symbol == TRADE_SYMBOL && magic == InpMagicNumber)
         count++;
   }

   return count;
}

//+------------------------------------------------------------------+
//| Calculate total profit for this EA's positions                    |
//+------------------------------------------------------------------+
double GetOwnProfit()
{
   double profit = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);

      if(symbol != TRADE_SYMBOL || magic != InpMagicNumber)
         continue;

      profit += PositionGetDouble(POSITION_PROFIT);
      profit += PositionGetDouble(POSITION_SWAP);
   }

   return profit;
}

//+------------------------------------------------------------------+
//| Close all positions for this EA                                   |
//+------------------------------------------------------------------+
bool CloseAllPositions()
{
   bool allOk = true;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);

      if(symbol != TRADE_SYMBOL || magic != InpMagicNumber)
         continue;

      if(!ClosePositionByTicket(ticket))
         allOk = false;
   }

   return allOk && (GetOwnOrderCount() == 0);
}

//+------------------------------------------------------------------+
//| Close single position                                            |
//+------------------------------------------------------------------+
bool ClosePositionByTicket(const ulong ticket)
{
   bool accepted = g_trade.PositionClose(ticket);
   if(!accepted)
   {
      Print("Close failed for ticket ", ticket,
            " retcode=", g_trade.ResultRetcode(),
            " desc=", g_trade.ResultRetcodeDescription());
      return false;
   }

   uint retcode = g_trade.ResultRetcode();
   if(retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_DONE_PARTIAL)
   {
      Print("Close rejected for ticket ", ticket,
            " retcode=", retcode,
            " desc=", g_trade.ResultRetcodeDescription());
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Get EMA10 value                                                   |
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
//| Convert price to grid level using 1-point spacing                 |
//+------------------------------------------------------------------+
double GridLevel(const double price)
{
   int digits = (int)SymbolInfoInteger(TRADE_SYMBOL, SYMBOL_DIGITS);
   return NormalizeDouble(MathFloor(price / g_gridStep) * g_gridStep, digits);
}

//+------------------------------------------------------------------+
//| Compare two grid levels                                          |
//+------------------------------------------------------------------+
bool SamePrice(const double first, const double second)
{
   double point = SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_POINT);
   return MathAbs(first - second) <= (point / 2.0);
}

//+------------------------------------------------------------------+
