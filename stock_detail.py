#!/usr/bin/env python3
"""
stock_detail.py - Detailed analysis fetcher for a single ticker.
Part of US Stock Screener v1.3.0.

Usage:  python stock_detail.py TICKER

Writes (all in ./data/):
    detail_summary.csv    - single row: header, returns, key stats, technicals
    detail_history.csv    - daily OHLCV + SMA50/SMA200 for past 1Y (~252 rows)
    detail_analysts.csv   - target prices + recommendation counts
    detail_earnings.csv   - next earnings date + last 4 surprises
    detail_status.txt     - running status line (UI polls this)
    detail_error.log      - traceback on hard failure

Resilience: matches v1.2.0's fast_info -> get_info() -> .info fallback pattern,
two retries with backoff on the main fetch, atomic CSV writes.

Total runtime: ~3-5 seconds per ticker.
"""

import os
import sys
import csv
import time
import math
import random
import traceback
from datetime import datetime

try:
    import yfinance as yf
    import pandas as pd
except ImportError as e:
    print(f"Missing dependency: {e}")
    print("Run: pip install yfinance pandas")
    sys.exit(1)


DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
os.makedirs(DATA_DIR, exist_ok=True)

STATUS_FILE  = os.path.join(DATA_DIR, "detail_status.txt")
SUMMARY_CSV  = os.path.join(DATA_DIR, "detail_summary.csv")
HISTORY_CSV  = os.path.join(DATA_DIR, "detail_history.csv")
ANALYSTS_CSV = os.path.join(DATA_DIR, "detail_analysts.csv")
EARNINGS_CSV = os.path.join(DATA_DIR, "detail_earnings.csv")
ERROR_LOG    = os.path.join(DATA_DIR, "detail_error.log")


# -------------- helpers --------------

def status(msg):
    """Single-line status the PowerShell UI polls."""
    try:
        with open(STATUS_FILE, "w", encoding="utf-8") as f:
            f.write(f"{datetime.now().strftime('%H:%M:%S')} {msg}\n")
    except Exception:
        pass
    print(msg, flush=True)


def atomic_write_csv(path, rows, header=None):
    """Write to .tmp then os.replace -- never leaves a half-written file."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        if header:
            w.writerow(header)
        for r in rows:
            w.writerow(r)
    os.replace(tmp, path)


def safe(val, default=""):
    """Coerce yfinance values; None / NaN / Inf -> default."""
    if val is None:
        return default
    try:
        f = float(val)
        if math.isnan(f) or math.isinf(f):
            return default
        return f
    except (TypeError, ValueError):
        return str(val)


def pct(new, old):
    """Percent change new/old - 1, rounded to 2dp. Returns "" if invalid."""
    try:
        new = float(new); old = float(old)
        if old == 0:
            return ""
        return round((new / old - 1) * 100, 2)
    except (TypeError, ValueError):
        return ""


def get_info_resilient(t):
    """fast_info first, then get_info(), then .info. Mirrors v1.2.0."""
    info = {}
    try:
        fi = t.fast_info
        for k in ("last_price", "previous_close", "market_cap",
                  "year_high", "year_low", "shares"):
            v = getattr(fi, k, None)
            if v is not None:
                info[k] = v
    except Exception:
        pass

    full = None
    for attempt in range(2):
        try:
            if hasattr(t, "get_info"):
                full = t.get_info()
            else:
                full = t.info
            if full:
                break
        except Exception:
            time.sleep(1.5 * (attempt + 1))

    if full:
        for k, v in full.items():
            if v is not None and info.get(k) is None:
                info[k] = v
    return info


def price_n_trading_days_ago(history_df, n):
    """Close N trading days before the most recent bar."""
    if history_df is None or history_df.empty:
        return None
    if len(history_df) <= n:
        return float(history_df["Close"].iloc[0])
    return float(history_df["Close"].iloc[-1 - n])


def find_close_on_or_before(history_df, target_date):
    """Last close on or before target_date (handles tz)."""
    if history_df is None or history_df.empty:
        return None
    try:
        target = pd.Timestamp(target_date)
        if history_df.index.tz is not None and target.tz is None:
            target = target.tz_localize(history_df.index.tz)
        sub = history_df.loc[history_df.index <= target]
        if sub.empty:
            return float(history_df["Close"].iloc[0])
        return float(sub["Close"].iloc[-1])
    except Exception:
        return None


def compute_rsi(close, period=14):
    """Wilder's RSI."""
    delta = close.diff()
    gain = delta.clip(lower=0)
    loss = -delta.clip(upper=0)
    avg_gain = gain.ewm(alpha=1 / period, adjust=False).mean()
    avg_loss = loss.ewm(alpha=1 / period, adjust=False).mean()
    rs = avg_gain / avg_loss.replace(0, 1e-10)
    return 100 - 100 / (1 + rs)


def compute_atr(df, period=14):
    """Average True Range over `period` bars."""
    high, low, close = df["High"], df["Low"], df["Close"]
    prev_close = close.shift(1)
    tr = pd.concat([
        (high - low),
        (high - prev_close).abs(),
        (low - prev_close).abs(),
    ], axis=1).max(axis=1)
    return tr.rolling(period).mean()


# -------------- main fetch --------------

def fetch_ticker_data(ticker):
    ticker = ticker.upper().strip()
    status(f"Fetching {ticker}: ticker object")
    t = yf.Ticker(ticker)

    # 1. Two years of history so the 200-day MA has values throughout the 1Y view.
    # v1.3.1: more aggressive retries -- yfinance returns an empty DataFrame (no
    # exception) when Yahoo throttles, so we now treat empty results the same
    # as exceptions. Exponential backoff: 2s, 5s, 11s. Max ~18s before giving up.
    status(f"Fetching {ticker}: 2y price history")
    hist = None
    last_err = None
    for attempt in range(4):
        try:
            hist = t.history(period="2y", auto_adjust=False)
            if hist is not None and not hist.empty:
                break
            last_err = "empty response (likely Yahoo throttle)"
        except Exception as e:
            last_err = str(e)
            hist = None
        if attempt < 3:
            wait = 2.0 * (2 ** attempt) + random.uniform(0, 1)
            status(f"Fetching {ticker}: history retry {attempt + 2}/4 in {wait:.1f}s ({last_err})")
            time.sleep(wait)
    if hist is None or hist.empty:
        raise RuntimeError(
            f"No price history for {ticker} after 4 attempts. "
            f"Last cause: {last_err}. "
            f"This is almost always a Yahoo rate limit -- wait 1-2 minutes and retry."
        )

    # 2. Company info (resilient)
    status(f"Fetching {ticker}: company info")
    info = get_info_resilient(t)

    # 3. Indicators on the full 2Y window, then slice to 1Y for output
    status(f"Computing {ticker}: indicators")
    hist["SMA50"]  = hist["Close"].rolling(50).mean()
    hist["SMA200"] = hist["Close"].rolling(200).mean()
    hist["RSI14"]  = compute_rsi(hist["Close"], 14)

    one_year = hist.tail(252).copy()

    last_row = hist.iloc[-1]
    current_price = float(last_row["Close"])
    prev_close = float(hist["Close"].iloc[-2]) if len(hist) >= 2 else current_price
    day_change = current_price - prev_close

    # Returns at standard horizons (trading days)
    px_1m  = price_n_trading_days_ago(hist, 21)
    px_3m  = price_n_trading_days_ago(hist, 63)
    px_6m  = price_n_trading_days_ago(hist, 126)
    px_1y  = price_n_trading_days_ago(hist, 252)
    px_ytd = find_close_on_or_before(hist, datetime(datetime.now().year, 1, 1))

    px_52w_high = float(hist["High"].tail(252).max())
    px_52w_low  = float(hist["Low"].tail(252).min())

    sma50  = float(last_row["SMA50"])  if not pd.isna(last_row["SMA50"])  else None
    sma200 = float(last_row["SMA200"]) if not pd.isna(last_row["SMA200"]) else None
    rsi14  = float(last_row["RSI14"])  if not pd.isna(last_row["RSI14"])  else None

    tr30 = compute_atr(hist, 30)
    atr30 = float(tr30.iloc[-1]) if not pd.isna(tr30.iloc[-1]) else None

    dollar_vol = (hist["Close"] * hist["Volume"]).rolling(30).mean()
    avg_dollar_vol_30 = float(dollar_vol.iloc[-1]) if not pd.isna(dollar_vol.iloc[-1]) else None

    # Fundamentals from info (with percent-normalization)
    name     = info.get("shortName") or info.get("longName") or ticker
    sector   = info.get("sector")   or ""
    industry = info.get("industry") or ""

    market_cap = safe(info.get("marketCap"))
    pe_ratio   = safe(info.get("trailingPE"))
    fwd_pe     = safe(info.get("forwardPE"))
    peg        = safe(info.get("trailingPegRatio") or info.get("pegRatio"))
    eps        = safe(info.get("trailingEps"))

    # yfinance has flip-flopped on whether dividendYield, profitMargins, ROE,
    # shortPercentOfFloat are returned as decimal (0.0052) or percent (0.52).
    # Normalize: if value is < 1, treat as decimal and multiply by 100.
    def to_pct(v):
        if isinstance(v, float):
            return round(v * 100, 2) if v < 1 else round(v, 2)
        return v

    div_yield     = to_pct(safe(info.get("dividendYield")))
    profit_margin = to_pct(safe(info.get("profitMargins")))
    roe           = to_pct(safe(info.get("returnOnEquity")))
    short_float   = to_pct(safe(info.get("shortPercentOfFloat")))

    beta        = safe(info.get("beta"))
    debt_equity = safe(info.get("debtToEquity"))

    px_vs_sma50  = pct(current_price, sma50)  if sma50  else ""
    px_vs_sma200 = pct(current_price, sma200) if sma200 else ""

    # ---- write summary CSV ----
    summary_header = [
        "Ticker","FetchTimestamp","Name","Sector","Industry",
        "CurrentPrice","PrevClose","DayChange","DayChangePct","DayAsOf",
        "Ret1M","Ret3M","Ret6M","RetYTD","Ret1Y",
        "Px1M","Px3M","Px6M","PxYTD","Px1Y",
        "Px52wHigh","Px52wLow","PctFrom52wHigh","PctFrom52wLow",
        "MarketCap","PERatio","ForwardPE","PEG","EPS",
        "DividendYieldPct","Beta","ProfitMarginPct","ROEPct",
        "DebtEquity","ShortFloatPct",
        "SMA50","SMA200","PxVsSMA50Pct","PxVsSMA200Pct",
        "RSI14","ATR30","AvgDollarVol30",
    ]
    summary_row = [
        ticker, datetime.now().isoformat(timespec="seconds"),
        name, sector, industry,
        round(current_price,4), round(prev_close,4),
        round(day_change,4), pct(current_price, prev_close),
        last_row.name.strftime("%Y-%m-%d") if hasattr(last_row.name,"strftime") else "",
        pct(current_price, px_1m), pct(current_price, px_3m),
        pct(current_price, px_6m),
        pct(current_price, px_ytd) if px_ytd else "",
        pct(current_price, px_1y),
        round(px_1m,4)  if px_1m  else "",
        round(px_3m,4)  if px_3m  else "",
        round(px_6m,4)  if px_6m  else "",
        round(px_ytd,4) if px_ytd else "",
        round(px_1y,4)  if px_1y  else "",
        round(px_52w_high,4), round(px_52w_low,4),
        pct(current_price, px_52w_high), pct(current_price, px_52w_low),
        market_cap, pe_ratio, fwd_pe, peg, eps,
        div_yield, beta, profit_margin, roe, debt_equity, short_float,
        round(sma50,4)  if sma50  else "",
        round(sma200,4) if sma200 else "",
        px_vs_sma50, px_vs_sma200,
        round(rsi14,2)  if rsi14  is not None else "",
        round(atr30,4)  if atr30  else "",
        round(avg_dollar_vol_30,0) if avg_dollar_vol_30 else "",
    ]
    atomic_write_csv(SUMMARY_CSV, [summary_row], summary_header)

    # ---- write history CSV (1Y of trading days, ~252 rows) ----
    status(f"Writing {ticker}: history CSV")
    hist_rows = []
    for idx, row in one_year.iterrows():
        # Skip no-trade days with missing OHLC - writing "nan" here would crash
        # the chart renderer (it casts these cells to double).
        if (pd.isna(row["Open"]) or pd.isna(row["High"])
                or pd.isna(row["Low"]) or pd.isna(row["Close"])):
            continue
        hist_rows.append([
            idx.strftime("%Y-%m-%d"),
            round(float(row["Open"]),4),
            round(float(row["High"]),4),
            round(float(row["Low"]),4),
            round(float(row["Close"]),4),
            int(row["Volume"]) if not pd.isna(row["Volume"]) else 0,
            round(float(row["SMA50"]),4)  if not pd.isna(row["SMA50"])  else "",
            round(float(row["SMA200"]),4) if not pd.isna(row["SMA200"]) else "",
        ])
    atomic_write_csv(HISTORY_CSV, hist_rows,
        ["Date","Open","High","Low","Close","Volume","SMA50","SMA200"])

    # ---- analyst targets + recommendations ----
    status(f"Fetching {ticker}: analyst data")
    a = {"TargetMean":"","TargetMedian":"","TargetHigh":"","TargetLow":"",
         "NumAnalysts":"","StrongBuy":"","Buy":"","Hold":"","Sell":"","StrongSell":""}

    # analyst_price_targets has been both a dict and a DataFrame across versions
    try:
        apt = t.analyst_price_targets
        if apt is not None:
            if isinstance(apt, dict):
                a["TargetMean"]   = safe(apt.get("mean"))
                a["TargetMedian"] = safe(apt.get("median"))
                a["TargetHigh"]   = safe(apt.get("high"))
                a["TargetLow"]    = safe(apt.get("low"))
            elif hasattr(apt, "iloc") and not apt.empty:
                row0 = apt.iloc[0] if len(apt) > 0 else {}
                for k_out, k_in in [("TargetMean","mean"),("TargetMedian","median"),
                                    ("TargetHigh","high"),("TargetLow","low")]:
                    try:
                        a[k_out] = safe(row0.get(k_in))
                    except Exception:
                        pass
    except Exception:
        pass

    # Fall back to .info if anything missing
    if not a["TargetMean"]:   a["TargetMean"]   = safe(info.get("targetMeanPrice"))
    if not a["TargetMedian"]: a["TargetMedian"] = safe(info.get("targetMedianPrice"))
    if not a["TargetHigh"]:   a["TargetHigh"]   = safe(info.get("targetHighPrice"))
    if not a["TargetLow"]:    a["TargetLow"]    = safe(info.get("targetLowPrice"))
    a["NumAnalysts"] = safe(info.get("numberOfAnalystOpinions"))

    upside_pct = pct(a["TargetMean"], current_price) if a["TargetMean"] else ""

    # Recommendation counts: DataFrame [period, strongBuy, buy, hold, sell, strongSell]
    try:
        recs = t.recommendations
        if recs is not None and not recs.empty:
            row0 = recs.iloc[0]
            for k_out, k_in in [("StrongBuy","strongBuy"),("Buy","buy"),
                                ("Hold","hold"),("Sell","sell"),
                                ("StrongSell","strongSell")]:
                v = row0.get(k_in, 0)
                try:
                    a[k_out] = int(v) if v is not None and not pd.isna(v) else 0
                except (TypeError, ValueError):
                    a[k_out] = 0
    except Exception:
        pass

    atomic_write_csv(ANALYSTS_CSV, [[
        ticker, a["TargetMean"], a["TargetMedian"], a["TargetHigh"], a["TargetLow"],
        upside_pct, a["NumAnalysts"],
        a["StrongBuy"], a["Buy"], a["Hold"], a["Sell"], a["StrongSell"],
    ]], ["Ticker","TargetMean","TargetMedian","TargetHigh","TargetLow",
         "UpsideMeanPct","NumAnalysts",
         "StrongBuy","Buy","Hold","Sell","StrongSell"])

    # ---- earnings: next date + last 4 surprises ----
    status(f"Fetching {ticker}: earnings")
    earn_rows = []
    try:
        ed = t.earnings_dates
        if ed is not None and not ed.empty:
            now = pd.Timestamp.now(tz=ed.index.tz) if ed.index.tz else pd.Timestamp.now()
            future = ed[ed.index >= now].sort_index()
            if not future.empty:
                nxt = future.iloc[0]
                eps_est = nxt.get("EPS Estimate", nxt.get("epsEstimate", ""))
                earn_rows.append([
                    future.index[0].strftime("%Y-%m-%d"),
                    safe(eps_est), "", "",
                ])
            past = ed[ed.index < now].sort_index(ascending=False).head(4)
            for idx, row in past.iterrows():
                eps_est  = row.get("EPS Estimate", row.get("epsEstimate", ""))
                eps_act  = row.get("Reported EPS", row.get("epsActual", ""))
                surprise = row.get("Surprise(%)", row.get("surprise", ""))
                earn_rows.append([
                    idx.strftime("%Y-%m-%d"),
                    safe(eps_est), safe(eps_act), safe(surprise),
                ])
    except Exception:
        pass
    atomic_write_csv(EARNINGS_CSV, earn_rows,
        ["DateOrLabel","EpsEstimate","EpsActual","SurprisePct"])

    status("Done")


def main():
    if len(sys.argv) < 2:
        status("Error: ticker argument required")
        print("Usage: python stock_detail.py TICKER")
        sys.exit(2)
    ticker = sys.argv[1].upper().strip()
    try:
        fetch_ticker_data(ticker)
    except Exception as e:
        status(f"Error: {e}")
        try:
            with open(ERROR_LOG, "w", encoding="utf-8") as f:
                f.write(traceback.format_exc())
        except Exception:
            pass
        sys.exit(1)


if __name__ == "__main__":
    main()
