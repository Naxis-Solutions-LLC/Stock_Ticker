"""
price_refresh.py - ROBUST live-price pull for a list of tickers.

This is the "real-time" half of the tool. It does NOT re-screen the universe;
it just grabs current price + 52-week high for tickers the UI asks about.

v1.2.0 changes (the "robust" pass):
  - .info fallback when fast_info returns None/partial
  - 2 retries with backoff on transient failures
  - Batches of 50 to give Yahoo room to breathe between bursts
  - Sleeps 1.0s between batches to avoid sustained rate-limiting
  - Atomic CSV write preserves last-known data on partial failure
    (we MERGE with the existing live_prices.csv rather than overwrite)

Usage:
    python price_refresh.py TICKER1 TICKER2 TICKER3 ...
    python price_refresh.py --file tickers.txt

Writes: data/live_prices.csv  with columns:
    Ticker, LivePrice, Live52WHigh, LivePctBelow, UpdatedAt
"""

import sys
import os
import csv
import time
import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed

try:
    import yfinance as yf
except ImportError:
    sys.stderr.write("yfinance not installed. Run: pip install yfinance\n")
    sys.exit(2)

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(HERE, "data")
OUT = os.path.join(DATA_DIR, "live_prices.csv")

# Tuning knobs - chosen to be polite to Yahoo while still finishing under 90s
# for ~715 tickers. Empirically: 50 per batch x 8 workers x ~1.5s settle =
# about 60-90s end-to-end for a full grid.
BATCH_SIZE = 50
MAX_WORKERS = 8
BATCH_DELAY = 1.0   # seconds between batches
RETRIES = 2         # try the slow .info fallback this many extra times


def _from_fast_info(ticker):
    """First attempt: fast_info is quick but flaky."""
    try:
        fi = yf.Ticker(ticker).fast_info
        price = fi.get("lastPrice") or fi.get("last_price")
        high = fi.get("yearHigh") or fi.get("year_high")
        if price is None:
            return None
        return (price, high)
    except Exception:
        return None


def _from_info(ticker):
    """Slow fallback: get_info() then .info, like the screener does."""
    try:
        t = yf.Ticker(ticker)
        info = None
        try:
            info = t.get_info()
        except Exception:
            try:
                info = t.info
            except Exception:
                info = None
        if not info:
            return None
        price = (info.get("regularMarketPrice") or
                 info.get("currentPrice") or
                 info.get("previousClose"))
        high = (info.get("fiftyTwoWeekHigh") or
                info.get("regularMarketDayHigh"))
        if price is None:
            return None
        return (price, high)
    except Exception:
        return None


def get_one(ticker):
    """Try fast_info first, fall back to .info, then retry .info once.
    Returns dict row or None. None means we genuinely couldn't get a price."""
    # Try fast path
    r = _from_fast_info(ticker)

    # Fall back to slow path with retries
    if r is None:
        for attempt in range(RETRIES):
            if attempt > 0:
                time.sleep(0.5 * (attempt + 1))
            r = _from_info(ticker)
            if r is not None:
                break

    if r is None:
        return None
    price, high = r
    pct_below = ""
    if high and high > 0 and price is not None:
        pct_below = round((high - price) / high * 100, 2)
    return {
        "Ticker": ticker,
        "LivePrice": round(price, 2) if price is not None else "",
        "Live52WHigh": round(high, 2) if high else "",
        "LivePctBelow": pct_below,
        "UpdatedAt": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    }


def read_ticker_args():
    """Tickers from CLI args, or from --file <path>."""
    args = sys.argv[1:]
    if not args:
        return []
    if args[0] == "--file":
        if len(args) < 2:
            return []
        try:
            with open(args[1], "r", encoding="utf-8") as f:
                return [ln.strip().upper() for ln in f if ln.strip()]
        except OSError:
            return []
    return [a.strip().upper() for a in args if a.strip()]


def load_existing():
    """Load existing live_prices.csv as a dict so we can MERGE rather than
    overwrite. This way, if a refresh only gets 39/715 tickers, the other
    676 keep their last-known prices instead of going to '-'."""
    existing = {}
    if not os.path.exists(OUT):
        return existing
    try:
        with open(OUT, "r", encoding="utf-8", newline="") as f:
            r = csv.DictReader(f)
            for row in r:
                tk = (row.get("Ticker") or "").strip().upper()
                if tk:
                    existing[tk] = row
    except Exception:
        pass
    return existing


def main():
    tickers = read_ticker_args()
    if not tickers:
        sys.stderr.write("No tickers given.\n")
        sys.exit(1)

    # Dedupe, keep order
    seen = set()
    uniq = []
    for t in tickers:
        if t not in seen:
            seen.add(t)
            uniq.append(t)

    os.makedirs(DATA_DIR, exist_ok=True)

    # Start with existing rows so we MERGE rather than overwrite
    merged = load_existing()
    new_count = 0
    fail_count = 0

    total = len(uniq)
    sys.stdout.write(f"Fetching {total} tickers in batches of {BATCH_SIZE}...\n")
    sys.stdout.flush()

    def flush_to_csv():
        """Atomic write of current merged state to live_prices.csv. Called
        after each batch so the UI can show progressive updates."""
        tmp = OUT + ".tmp"
        fields = ["Ticker", "LivePrice", "Live52WHigh", "LivePctBelow", "UpdatedAt"]
        with open(tmp, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=fields)
            w.writeheader()
            written = set()
            for t in uniq:
                tu = t.upper()
                if tu in merged:
                    w.writerow(merged[tu])
                    written.add(tu)
            for tu, row in merged.items():
                if tu not in written:
                    w.writerow(row)
        os.replace(tmp, OUT)

    # Process in batches
    for batch_start in range(0, total, BATCH_SIZE):
        batch = uniq[batch_start:batch_start + BATCH_SIZE]
        with ThreadPoolExecutor(max_workers=MAX_WORKERS) as ex:
            futures = {ex.submit(get_one, t): t for t in batch}
            for fut in as_completed(futures):
                tk = futures[fut]
                row = fut.result()
                if row:
                    merged[tk.upper()] = row
                    new_count += 1
                else:
                    fail_count += 1
        done = min(batch_start + BATCH_SIZE, total)
        # Flush after each batch so the UI sees progress
        flush_to_csv()
        sys.stdout.write(f"  Batch done: {done}/{total} (updated {new_count}, failed {fail_count})\n")
        sys.stdout.flush()
        # Be polite between batches
        if done < total:
            time.sleep(BATCH_DELAY)

    sys.stdout.write(f"Done. Updated {new_count}/{total} tickers ({fail_count} failed). Total rows in CSV: {len(merged)}.\n")


if __name__ == "__main__":
    main()
