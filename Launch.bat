@echo off
REM ============================================================
REM  US Stock Screener - UI Launcher
REM  Double-click this to open the screener window.
REM ============================================================
REM
REM  This black window is a LOG WINDOW. It is safe to minimize. It
REM  only exists so that if the app hits an error before its window
REM  appears, you can see (and copy) the message here instead of the
REM  app just vanishing. You can ignore it once the app is open.
REM ============================================================

echo Starting US Stock Screener UI...
echo (This is just a log window - safe to minimize.)
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0StockUI.ps1"

echo.
echo The UI has closed. If there was an error above, or in error_log.txt,
echo paste it for help.
pause
