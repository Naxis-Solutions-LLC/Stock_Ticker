"""
screener_full.py - the SLOW full-universe screen (v4: full spec)

HARD FILTERS (a stock must pass all of these to appear):
  - Current price between $10 and $60                         (#6)
  - Market cap over $500M                                     (#4)
  - Current price below 52-week high                          (#8)
  - Average daily share volume > 500,000                      (#5)
  - Average daily dollar volume > $5,000,000                  (#7)

TAGGED (written as columns, filtered in the UI - NOT hard filters):
  - Sector, Industry                                          (#2, #3)
  - Index membership: SP500 / Nasdaq100 / Dow30               (#1)
  - AI (curated) flag, Uranium flag                           (#3)
  - 3-month % change and trend slope                          (#9)

Writes data/screen_data.csv with progress to data/screen_status.txt.
Takes ~25-40 minutes (pulls history + info per ticker, ~6,900 US tickers).
"""

import time
import io
import os
import sys
import csv
import random
import datetime
import requests
import yfinance as yf
from concurrent.futures import ThreadPoolExecutor, as_completed

# ---- Hard filter thresholds ----
MIN_PRICE = 10.0
MAX_PRICE = 60.0
MIN_MARKET_CAP = 500_000_000
MIN_AVG_VOLUME = 500_000           # shares/day  (#5)
MIN_AVG_DOLLAR_VOL = 5_000_000     # $/day       (#7)

# ---- Performance ----
MAX_WORKERS = 8
MAX_RETRIES = 3
BASE_BACKOFF = 2.0
SKIP_SUFFIXES = ("-W", "-WS", "-U", "-R", "-RT", ".W", ".U", ".WS")
DEEP_DROP_FLAG = 70.0

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(HERE, "data")
OUT_CSV = os.path.join(DATA_DIR, "screen_data.csv")
STATUS = os.path.join(DATA_DIR, "screen_status.txt")
META = os.path.join(DATA_DIR, "screen_meta.txt")

_done = 0
_total = 0

# ---- Curated AI list (honest approximation - no official Yahoo "AI" industry) ----
AI_CURATED = {
    "NVDA", "AMD", "AVGO", "MRVL", "SMCI", "ARM", "TSM", "MU", "INTC",
    "PLTR", "AI", "BBAI", "SOUN", "PATH", "SNOW", "DDOG", "NOW", "CRM",
    "MSFT", "GOOGL", "GOOG", "META", "AMZN", "IBM", "ORCL", "ADBE",
    "CRWD", "PANW", "ANET", "DELL", "HPE", "VRT", "MDB", "ESTC",
    "TEM", "RXRX", "CRNC", "AIFU", "GFAI", "INOD", "VERI",
}


def write_status(msg):
    try:
        with open(STATUS, "w", encoding="utf-8") as f:
            f.write(msg)
    except OSError:
        pass


def get_index_members():
    headers = {"User-Agent": "Mozilla/5.0"}
    members = {}

    def add(tkr, idx):
        tkr = tkr.strip().upper().replace(".", "-")
        members.setdefault(tkr, set()).add(idx)

    sources = [
        ("SP500", "https://en.wikipedia.org/wiki/List_of_S%26P_500_companies"),
        ("Dow30", "https://en.wikipedia.org/wiki/Dow_Jones_Industrial_Average"),
        ("Nasdaq100", "https://en.wikipedia.org/wiki/Nasdaq-100"),
    ]
    import pandas as pd
    for idx_name, url in sources:
        try:
            r = requests.get(url, headers=headers, timeout=20)
            r.raise_for_status()
            tables = pd.read_html(io.StringIO(r.text))
            for tbl in tables:
                cols = [str(c) for c in tbl.columns]
                tcol = None
                for c in cols:
                    if c in ("Symbol", "Ticker", "Ticker symbol"):
                        tcol = c
                        break
                if tcol is not None:
                    for v in tbl[tcol].dropna().astype(str):
                        add(v, idx_name)
                    break
        except Exception as e:
            sys.stderr.write(f"  ! index fetch {idx_name} failed: {e}\n")
    return members


def get_us_tickers():
    headers = {"User-Agent": "Mozilla/5.0"}
    urls = {
        "nasdaq": "https://www.nasdaqtrader.com/dynamic/SymDir/nasdaqlisted.txt",
        "other":  "https://www.nasdaqtrader.com/dynamic/SymDir/otherlisted.txt",
    }
    tickers = set()
    import pandas as pd
    for name, url in urls.items():
        try:
            r = requests.get(url, headers=headers, timeout=20)
            r.raise_for_status()
            df = pd.read_csv(io.StringIO(r.text), sep="|")
            df = df[df.iloc[:, 0].astype(str).str.match(r"^[A-Z]")]
            if "Test Issue" in df.columns:
                df = df[df["Test Issue"] == "N"]
            if "ETF" in df.columns:
                df = df[df["ETF"] == "N"]
            symbol_col = "Symbol" if "Symbol" in df.columns else "ACT Symbol"
            tickers.update(df[symbol_col].dropna().astype(str).tolist())
        except Exception as e:
            sys.stderr.write(f"  ! Could not fetch {name}: {e}\n")
    cleaned = []
    for t in tickers:
        t = t.strip().upper()
        if not t or "$" in t or " " in t:
            continue
        if any(t.endswith(suf) for suf in SKIP_SUFFIXES):
            continue
        cleaned.append(t.replace(".", "-"))
    return sorted(set(cleaned))


def linreg_slope(values):
    n = len(values)
    if n < 2:
        return 0.0
    xs = list(range(n))
    mean_x = sum(xs) / n
    mean_y = sum(values) / n
    num = sum((xs[i] - mean_x) * (values[i] - mean_y) for i in range(n))
    den = sum((xs[i] - mean_x) ** 2 for i in range(n))
    if den == 0:
        return 0.0
    return num / den


def screen_one(ticker, index_members):
    global _done
    for attempt in range(MAX_RETRIES):
        try:
            tk = yf.Ticker(ticker)
            hist = tk.history(period="1y", auto_adjust=True)
            if hist is None or hist.empty or "High" not in hist:
                _done += 1
                return None

            high_52w = float(hist["High"].max())
            price = float(hist["Close"].iloc[-1])

            recent = hist.tail(63)  # ~3 trading months
            avg_vol = float(recent["Volume"].mean()) if "Volume" in recent else 0.0
            avg_dollar_vol = avg_vol * price

            closes_3m = list(recent["Close"].dropna())
            if len(closes_3m) >= 2:
                px_3mo_ago = closes_3m[0]
                pct_3mo = (price - px_3mo_ago) / px_3mo_ago * 100 if px_3mo_ago else 0.0
                slope = linreg_slope(closes_3m)
                trend_up = (price > px_3mo_ago) and (slope > 0)
            else:
                px_3mo_ago = price  # so the column isn't blank
                pct_3mo = 0.0
                slope = 0.0
                trend_up = False

            mcap = None
            sector = ""
            industry = ""
            try:
                fi = tk.fast_info
                mcap = fi.get("marketCap") or fi.get("market_cap")
            except Exception:
                pass
            # yfinance exposes company info as either get_info() (newer) or
            # the .info property (older). Try both so sector/industry actually
            # populate regardless of installed yfinance version.
            info = None
            try:
                info = tk.get_info()
            except Exception:
                try:
                    info = tk.info
                except Exception:
                    info = None
            if info:
                try:
                    if mcap is None:
                        mcap = info.get("marketCap")
                    sector = (info.get("sector") or "").strip()
                    industry = (info.get("industry") or "").strip()
                except Exception:
                    pass
            if mcap is None:
                _done += 1
                return None

            if not (MIN_PRICE <= price <= MAX_PRICE):
                _done += 1
                return None
            if mcap < MIN_MARKET_CAP:
                _done += 1
                return None
            if price >= high_52w:
                _done += 1
                return None
            if avg_vol < MIN_AVG_VOLUME:
                _done += 1
                return None
            if avg_dollar_vol < MIN_AVG_DOLLAR_VOL:
                _done += 1
                return None

            pct_off = (high_52w - price) / high_52w * 100
            flag = f"Check: {pct_off:.0f}% below high" if pct_off >= DEEP_DROP_FLAG else ""

            idxs = index_members.get(ticker.upper(), set())
            is_ai = "Y" if ticker.upper() in AI_CURATED else ""
            is_uranium = "Y" if "uranium" in industry.lower() else ""

            _done += 1
            return {
                "Ticker": ticker,
                "Price": round(price, 2),
                "High52W": round(high_52w, 2),
                "PctBelow": round(pct_off, 2),
                "MarketCapM": round(mcap / 1_000_000, 1),
                "AvgVolK": round(avg_vol / 1_000, 1),
                "AvgDolVolM": round(avg_dollar_vol / 1_000_000, 2),
                "Sector": sector,
                "Industry": industry,
                "Indexes": "|".join(sorted(idxs)),
                "AI": is_ai,
                "Uranium": is_uranium,
                "Chg3moPct": round(pct_3mo, 2),
                "Px3moAgo": round(px_3mo_ago, 2),
                "TrendUp": "Y" if trend_up else "",
                "DataFlag": flag,
            }

        except Exception as e:
            msg = str(e).lower()
            if "429" in msg or "rate" in msg or "too many" in msg:
                time.sleep(BASE_BACKOFF * (2 ** attempt) + random.uniform(0, 1))
                continue
            _done += 1
            return None
    _done += 1
    return None


def main():
    global _total
    os.makedirs(DATA_DIR, exist_ok=True)
    write_status("Starting: fetching index membership lists...")
    index_members = get_index_members()

    write_status("Fetching ticker universe...")
    tickers = get_us_tickers()
    _total = len(tickers)
    if not tickers:
        write_status("ERROR: no tickers retrieved.")
        sys.exit(1)

    write_status(f"Screening 0 / {_total} ...")
    results = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as ex:
        futures = {ex.submit(screen_one, t, index_members): t for t in tickers}
        last_update = 0
        for fut in as_completed(futures):
            row = fut.result()
            if row:
                results.append(row)
            if _done - last_update >= 50:
                last_update = _done
                write_status(f"Screening {_done} / {_total}  -  {len(results)} passed so far")

    results.sort(key=lambda r: r["PctBelow"], reverse=True)

    tmp = OUT_CSV + ".tmp"
    fields = ["Ticker", "Price", "High52W", "PctBelow", "MarketCapM",
              "AvgVolK", "AvgDolVolM", "Sector", "Industry", "Indexes",
              "AI", "Uranium", "Chg3moPct", "Px3moAgo", "TrendUp", "DataFlag"]
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        for row in results:
            w.writerow(row)
    os.replace(tmp, OUT_CSV)

    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(META, "w", encoding="utf-8") as f:
        f.write(f"last_run={stamp}\n")
        f.write(f"total_screened={_total}\n")
        f.write(f"passed={len(results)}\n")

    write_status(f"DONE  -  {len(results)} stocks passed  ({stamp})")
    sys.stdout.write(f"Done. {len(results)} passed. -> {OUT_CSV}\n")


if __name__ == "__main__":
    main()
