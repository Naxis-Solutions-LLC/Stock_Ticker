===============================================================
              US STOCK SCREENER - START HERE
===============================================================

Hi! Someone shared this stock screener with you. Here's how to
get it running in about 5 minutes.

---------------------------------------------------------------
STEP 1 - EXTRACT THIS ZIP
---------------------------------------------------------------
If you're reading this from inside the zip, first extract the
WHOLE FOLDER somewhere on your computer (Documents, Desktop,
wherever). Right-click the zip and pick "Extract All...".

Don't just open the zip - the app needs the files unpacked.

---------------------------------------------------------------
STEP 2 - RUN SETUP (ONCE)
---------------------------------------------------------------
Double-click  Setup.bat

It will:
  - Check that Python is installed (free, from python.org)
  - Install the small libraries the screener needs
  - Put a "Stock Screener" shortcut on your Desktop

If Python isn't installed, Setup will offer to open the
download page for you. When you install Python, MAKE SURE to
check the box that says "Add Python to PATH" - otherwise
nothing will find it later.

---------------------------------------------------------------
STEP 3 - USE IT
---------------------------------------------------------------
Double-click the "Stock Screener" shortcut on your Desktop.

A console window opens (you can minimize it, but don't close
it). The main app window appears over it.

FIRST RUN: the Screen tab will already be populated with the
data the original sender bundled. Or you can click "Re-run
Full Screen" to pull fresh data (takes 25-40 minutes - it
runs in the background, you can keep using the app).

---------------------------------------------------------------
WHAT THE TABS DO
---------------------------------------------------------------
SCREEN      - All stocks that match the criteria. Filter,
              sort, live price refresh every 60 seconds.

COHORTS     - The top 15 stocks furthest below their 52-week
              high, broken out by price band.

TEST TRADES - Paper-trading log. Type a ticker; today's
              date and current price auto-fill. Enter a Qty,
              watch P/L update live. Add a Sell Price to
              close the trade.

---------------------------------------------------------------
TROUBLESHOOTING
---------------------------------------------------------------
"Python isn't found" - Setup.bat will tell you how to install
it. The key thing during install: CHECK "Add Python to PATH".

"The window flashes and disappears" - Don't run StockUI.ps1
directly. Always use Launch.bat or the Desktop shortcut. They
handle the Windows security policy that blocks PowerShell
scripts by default.

"An error popped up" - There's a try/catch that should show
you the line and the cause. There will also be an
error_log.txt file in the folder. Send that to whoever shared
this with you.

---------------------------------------------------------------
WHAT THIS IS / WHAT IT ISN'T
---------------------------------------------------------------
It's a free Yahoo Finance screener with a desktop UI.
Stock prices are delayed about 15 minutes (free data feed).

It is NOT trading software. It does not place orders, connect
to brokers, or know about your real money. Test Trades are
paper - just a log to track ideas.

===============================================================
