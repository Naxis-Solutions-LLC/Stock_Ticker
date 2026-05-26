@echo off
REM ============================================================
REM  US Stock Screener - UI Launcher
REM  Double-click this to open the screener window.
REM ============================================================
REM
REM  The console window stays open on purpose: if the UI hits an
REM  error before the window appears, you'll see it here instead
REM  of the window just vanishing. Once the UI window is open you
REM  can minimize this console - just don't close it.
REM ============================================================

echo Starting US Stock Screener UI...
echo (Keep this window open while using the app. Minimize it if you like.)
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0StockUI.ps1"

echo.
echo The UI has closed. If there was an error above, or in error_log.txt,
echo paste it for help.
pause
