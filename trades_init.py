"""
trades_init.py - ensures data/trades.csv exists with the right header.

The UI reads and writes trades.csv directly (it's just a CSV), but this
script guarantees the file exists with the correct columns on first run,
and can be used to reset the trade log if needed.

Columns:
    Ticker, BuyDate, BuyPrice, Qty, SellDate, SellPrice, Notes

Everything else (Investment, Current Value, P/L, Status) is computed
live in the UI - it is NOT stored, so there's no stale-math problem.

Usage:
    python trades_init.py          # create if missing, leave existing alone
    python trades_init.py --reset  # wipe and recreate empty (asks nothing - be sure)
"""

import os
import sys
import csv

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(HERE, "data")
TRADES = os.path.join(DATA_DIR, "trades.csv")

HEADER = ["Ticker", "BuyDate", "BuyPrice", "Qty", "SellDate", "SellPrice", "Notes"]

# A few example rows so the tab isn't empty on first open
SEED = [
    ["RBLX", "2026-05-01", "41.69", "100", "", "", "example - delete me"],
    ["WIX",  "2026-05-05", "54.70", "50",  "", "", "example - delete me"],
    ["GLOB", "2026-04-20", "33.71", "75",  "", "", "example - delete me"],
]


def main():
    os.makedirs(DATA_DIR, exist_ok=True)
    reset = "--reset" in sys.argv[1:]

    if os.path.exists(TRADES) and not reset:
        sys.stdout.write(f"trades.csv already exists - leaving it alone.\n")
        return

    tmp = TRADES + ".tmp"
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(HEADER)
        if not reset:  # only seed on first creation, not on explicit reset
            for row in SEED:
                w.writerow(row)
    os.replace(tmp, TRADES)

    action = "Reset" if reset else "Created"
    sys.stdout.write(f"{action} trades.csv -> {TRADES}\n")


if __name__ == "__main__":
    main()
