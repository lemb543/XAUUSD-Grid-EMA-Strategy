//+------------------------------------------------------------------+
//| XAUUSDm_EMA_Grid_Bot.mq5                                         |
//|                                                                  |
//| Rules:                                                           |
//| 1. Start each cycle with one BUY and one SELL.                   |
//| 2. Use EMA period 1 on M1 for grid direction.                    |
//| 3. At a new grid level, wait for the next tick confirmation.     |
//| 4. After confirmation, open one BUY above EMA1 or one SELL below  |
//|    EMA1.                                                         |
//| 5. Maximum open positions per cycle = 10.                        |
//| 6. If ANY EA position closes, close all remaining EA positions.  |
//| 7. After all positions are closed, reset and start a new cycle.  |
//| 8. Requires an MT5 hedging account.                              |
//+------------------------------------------------------------------+
#property strict
#property version "1.06"

#include <Trade/Trade.mqh>

input double InpLotSize          = 0.01;       // Lot size per order
input int    InpGridPoints       = 1;          // Grid spacing in points
input int    InpEMAPeriod        = 1;          // EMA period
input ulong  InpMagicNumber      = 20260917;   // Unique magic number
input int    InpDeviationPoints  = 20;         // Maximum slippage
input int    InpMaxPositions     = 10;         // Maximum positions per cycle

const string TRADE_SYMBOL = "XAUUSDm";
const ENUM_TIMEFRAMES TRADE_TIMEFRAME = PERIOD_M1;

CTrade g_trade;
int    g_emaHandle = INVALID_HANDLE;
double g_gridStep = 0.0;
double g_lastGridLevel = 0.0;
double g_pendingGridLevel = 0.0;
int    g_pendingDirection = 0;                 // 1 = BUY, -1 = SELL
bool   g_cycleStarted = false;
bool   g_closingBasket = false;

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

   if(SymbolInfoInteger(TRADE_SYMBOL, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
   {
      Alert("Trading is disabled for XAUUSDm.");
      return INIT_FAILED;
   }

   ENUM_ACCOUNT_MARGIN_MODE marginMode =
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);

   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Alert("This strategy requires a hedging MT5 account.");
      return INIT_FAILED;
   }

   if(InpLotSize <= 0.0 || InpGridPoints <= 0 || InpEMAPeriod <= 0 || InpMaxPositions < 2)
   {
      Alert("Invalid input values.");
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
      Alert("Could not create EMA indicator.");
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(TRADE_SYMBOL);

   int count = GetOwnPositionCount();
   if(count > 0)
   {
      g_cycleStarted = true;

      MqlTick tick;
      if(SymbolInfoTick(TRADE_SYMBOL, tick))
         g_lastGridLevel = GridLevel((tick.bid + tick.ask) / 2.0);
   }

   Print("==============================================");
   Print("XAUUSDm EMA Grid Bot initialized");
   Print("EMA period: ", InpEMAPeriod);
   Print("Grid spacing: ", InpGridPoints, " point(s)");
   Print("Maximum positions per cycle: ", InpMaxPositions);
   Print("Confirmation: next tick after a new grid level");
   Print("Any closed position closes all remaining positions");
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
   if(Symbol() != TRADE_SYMBOL || g_closingBasket)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(TRADE_SYMBOL, tick))
      return;

   if(tick.bid <= 0.0 || tick.ask <= 0.0)
      return;

   int positionCount = GetOwnPositionCount();

   if(positionCount == 0)
   {
      g_cycleStarted = false;
      g_lastGridLevel = 0.0;
      g_pendingGridLevel = 0.0;
      g_pendingDirection = 0;
   }

   if(positionCount >= InpMaxPositions)
      return;

   double ema = GetEMA();
   if(ema <= 0.0)
      return;

   double currentPrice = (tick.bid + tick.ask) / 2.0;
   double currentGrid = GridLevel(currentPrice);

   // Start each cycle with BUY + SELL.
   if(!g_cycleStarted)
   {
      if(OpenInitialHedgePair())
      {
         g_cycleStarted = true;
         g_lastGridLevel = currentGrid;
         g_pendingGridLevel = 0.0;
         g_pendingDirection = 0;
      }
      return;
   }

   if(GetOwnPositionCount() >= InpMaxPositions)
      return;

   // First tick at a new grid: remember the direction and wait.
   if(!SamePrice(currentGrid, g_lastGridLevel))
   {
      int direction = 0;

      if(currentPrice > ema)
         direction = 1;
      else if(currentPrice < ema)
         direction = -1;

      if(direction != 0)
      {
         g_pendingGridLevel = currentGrid;
         g_pendingDirection = direction;
      }

      return;
   }

   // Next tick confirmation must still be at the same new grid level.
   if(g_pendingDirection != 0 && SamePrice(currentGrid, g_pendingGridLevel))
   {
      bool opened = false;

      if(g_pendingDirection == 1 && currentPrice > ema)
         opened = OpenBuyOnly();
      else if(g_pendingDirection == -1 && currentPrice < ema)
         opened = OpenSellOnly();

      if(opened)
      {
         g_lastGridLevel = currentGrid;
         g_pendingGridLevel = 0.0;
         g_pendingDirection = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| Any position closure closes the entire EA basket                  |
//+------------------------------------------------------------------+
void OnTradeTransaction(
   const MqlTradeTransaction &transaction,
   const MqlTradeRequest &request,
   const MqlTradeResult &result
)
{
   if(transaction.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong dealTicket = transaction.deal;
   if(dealTicket == 0 || !HistoryDealSelect(dealTicket))
      return;

   string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   ulong magic = (ulong)HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   ENUM_DEAL_ENTRY entry =
      (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);

   if(symbol != TRADE_SYMBOL || magic != InpMagicNumber)
      return;

   // Ignore opening deals; react only when a position is closed.
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;

   if(g_closingBasket)
      return;

   Print("One EA position closed. Closing all remaining EA positions.");

   g_closingBasket = true;
   CloseAllPositions();

   if(GetOwnPositionCount() == 0)
   {
      g_cycleStarted = false;
      g_lastGridLevel = 0.0;
      g_pendingGridLevel = 0.0;
      g_pendingDirection = 0;
      Print("All positions closed. Cycle reset.");
   }

   g_closingBasket = false;
}

//+------------------------------------------------------------------+
//| Open initial BUY + SELL pair                                      |
//+------------------------------------------------------------------+
bool OpenInitialHedgePair()
{
   if(GetOwnPositionCount() != 0)
      return false;

   bool buyOK = g_trade.Buy(
      InpLotSize,
      TRADE_SYMBOL,
      0.0,
      0.0,
      0.0,
      "INIT_BUY"
   );

   ulong buyTicket = g_trade.ResultOrder();

   if(!buyOK)
   {
      Print("Initial BUY failed: ", g_trade.ResultRetcodeDescription());
      return false;
   }

   bool sellOK = g_trade.Sell(
      InpLotSize,
      TRADE_SYMBOL,
      0.0,
      0.0,
      0.0,
      "INIT_SELL"
   );

   ulong sellTicket = g_trade.ResultOrder();

   if(!sellOK)
   {
      Print("Initial SELL failed: ", g_trade.ResultRetcodeDescription());
      ClosePositionByTicket(buyTicket);
      return false;
   }

   Print("Initial BUY + SELL opened. Buy ticket=", buyTicket,
         ", Sell ticket=", sellTicket);
   return true;
}

//+------------------------------------------------------------------+
//| Open BUY at a confirmed new grid level                            |
//+------------------------------------------------------------------+
bool OpenBuyOnly()
{
   if(GetOwnPositionCount() >= InpMaxPositions)
      return false;

   bool ok = g_trade.Buy(
      InpLotSize,
      TRADE_SYMBOL,
      0.0,
      0.0,
      0.0,
      "GRID_BUY_EMA1"
   );

   if(ok)
      Print("Confirmed EMA1 grid BUY opened.");
   else
      Print("Grid BUY failed: ", g_trade.ResultRetcodeDescription());

   return ok;
}

//+------------------------------------------------------------------+
//| Open SELL at a confirmed new grid level                           |
//+------------------------------------------------------------------+
bool OpenSellOnly()
{
   if(GetOwnPositionCount() >= InpMaxPositions)
      return false;

   bool ok = g_trade.Sell(
      InpLotSize,
      TRADE_SYMBOL,
      0.0,
      0.0,
      0.0,
      "GRID_SELL_EMA1"
   );

   if(ok)
      Print("Confirmed EMA1 grid SELL opened.");
   else
      Print("Grid SELL failed: ", g_trade.ResultRetcodeDescription());

   return ok;
}

//+------------------------------------------------------------------+
//| Count all positions owned by this EA                              |
//+------------------------------------------------------------------+
int GetOwnPositionCount()
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(IsOwnPosition())
         count++;
   }

   return count;
}

//+------------------------------------------------------------------+
//| Close every remaining position owned by this EA                   |
//+------------------------------------------------------------------+
bool CloseAllPositions()
{
   bool allOk = true;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(!IsOwnPosition())
         continue;

      if(!ClosePositionByTicket(ticket))
         allOk = false;
   }

   if(GetOwnPositionCount() > 0)
      allOk = false;

   return allOk;
}

//+------------------------------------------------------------------+
//| Close one position                                               |
//+------------------------------------------------------------------+
bool ClosePositionByTicket(const ulong ticket)
{
   bool accepted = g_trade.PositionClose(ticket);

   if(!accepted)
   {
      Print("Close failed for ticket ", ticket,
            ". Retcode=", g_trade.ResultRetcode(),
            ". Description=", g_trade.ResultRetcodeDescription());
      return false;
   }

   uint retcode = g_trade.ResultRetcode();

   if(retcode != TRADE_RETCODE_DONE &&
      retcode != TRADE_RETCODE_DONE_PARTIAL)
   {
      Print("Close rejected for ticket ", ticket,
            ". Retcode=", retcode,
            ". Description=", g_trade.ResultRetcodeDescription());
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Check whether the selected position belongs to this EA            |
//+------------------------------------------------------------------+
bool IsOwnPosition()
{
   string symbol = PositionGetString(POSITION_SYMBOL);
   ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);

   return symbol == TRADE_SYMBOL && magic == InpMagicNumber;
}

//+------------------------------------------------------------------+
//| Get EMA value                                                     |
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
//| Convert price to grid level                                      |
//+------------------------------------------------------------------+
double GridLevel(const double price)
{
   int digits = (int)SymbolInfoInteger(TRADE_SYMBOL, SYMBOL_DIGITS);
   return NormalizeDouble(MathFloor(price / g_gridStep) * g_gridStep, digits);
}

//+------------------------------------------------------------------+
//| Compare grid levels                                               |
//+------------------------------------------------------------------+
bool SamePrice(const double first, const double second)
{
   double point = SymbolInfoDouble(TRADE_SYMBOL, SYMBOL_POINT);
   return MathAbs(first - second) <= point / 2.0;
}

//+------------------------------------------------------------------+
