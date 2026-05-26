@echo off
setlocal enabledelayedexpansion
title US Stock Screener - First-Time Setup

REM ============================================================
REM  US Stock Screener - First-Time Setup
REM  Run this ONCE after extracting the zip. It will:
REM    1. Check that Python is installed (offer to open the
REM       download page if not)
REM    2. Install the libraries the screener needs
REM    3. Create a Desktop shortcut to launch the app
REM ============================================================

color 0B
cls
echo  ===============================================================
echo                    US STOCK SCREENER - SETUP
echo  ===============================================================
echo.
echo   This will set up the screener on your computer.
echo   It only needs to run once.
echo.
echo   Steps:
echo     1. Check for Python (free, from python.org)
echo     2. Install the libraries the screener needs
echo     3. Create a Desktop shortcut
echo.
echo  ---------------------------------------------------------------
echo.
pause

REM ============================================================
REM  Step 1: Find Python
REM ============================================================
echo.
echo  [1/3] Checking for Python...
echo.
set PY=
where python >nul 2>nul
if %errorlevel%==0 (
    set PY=python
    goto have_python
)
where py >nul 2>nul
if %errorlevel%==0 (
    set PY=py
    goto have_python
)

REM No Python found
color 0E
echo  +-------------------------------------------------------------+
echo  ^|  Python is NOT installed on this computer.                  ^|
echo  ^|                                                             ^|
echo  ^|  Python is free, takes about 2 minutes to install, and      ^|
echo  ^|  the screener can't run without it.                         ^|
echo  ^|                                                             ^|
echo  ^|  Download page: https://www.python.org/downloads/           ^|
echo  ^|                                                             ^|
echo  ^|  IMPORTANT: when installing, CHECK the box that says        ^|
echo  ^|  "Add Python to PATH" - otherwise this setup won't find it. ^|
echo  +-------------------------------------------------------------+
echo.
choice /C YN /M "Open the Python download page in your browser now"
if errorlevel 2 goto python_skip
start https://www.python.org/downloads/
echo.
echo  After you install Python (with "Add to PATH" checked),
echo  close this window and run Setup.bat again.
echo.
pause
exit /b 1

:python_skip
echo.
echo  No problem. When you're ready, install Python from
echo  https://www.python.org/downloads/ and run Setup.bat again.
echo.
pause
exit /b 1

:have_python
color 0A
echo  Found Python: !PY!
for /f "tokens=*" %%v in ('!PY! --version 2^>^&1') do echo  Version:      %%v
echo.

REM ============================================================
REM  Step 2: Install the libraries
REM ============================================================
echo.
echo  [2/3] Installing the libraries the screener uses...
echo        (yfinance, pandas, requests - first time takes 1-2 min)
echo.

!PY! -m pip install --quiet --upgrade pip 2>nul
!PY! -m pip install --quiet --upgrade yfinance pandas requests openpyxl
if %errorlevel% neq 0 (
    color 0C
    echo.
    echo  !!! Installation hit a problem.
    echo.
    echo  Try running this command yourself in a terminal:
    echo     !PY! -m pip install yfinance pandas requests openpyxl
    echo.
    pause
    exit /b 1
)
echo  Libraries installed.
echo.

REM ============================================================
REM  Step 3: Create Desktop shortcut
REM ============================================================
echo.
echo  [3/3] Creating Desktop shortcut...
echo.

set TARGET=%~dp0Launch.bat
set ICON=%SystemRoot%\System32\imageres.dll, -114

powershell -NoProfile -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Desktop') + '\Stock Screener.lnk'); $s.TargetPath='%TARGET%'; $s.WorkingDirectory='%~dp0'; $s.IconLocation='%ICON%'; $s.Description='US Stock Screener'; $s.Save()" 2>nul

if exist "%USERPROFILE%\Desktop\Stock Screener.lnk" (
    echo  Shortcut created: "Stock Screener" on your Desktop.
) else (
    echo  Could not create Desktop shortcut automatically.
    echo  You can still launch the app by double-clicking Launch.bat here.
)
echo.

REM ============================================================
REM  Done
REM ============================================================
color 0A
echo  ===============================================================
echo                          SETUP COMPLETE
echo  ===============================================================
echo.
echo   Double-click "Stock Screener" on your Desktop to start.
echo   (Or double-click Launch.bat in this folder.)
echo.
echo   First-time use: the screener tab will be empty until you
echo   click "Re-run Full Screen" - that takes 25-40 minutes the
echo   first time as it pulls data from Yahoo Finance.
echo.
echo  ---------------------------------------------------------------
echo.
choice /C YN /M "Launch the Stock Screener now"
if errorlevel 2 goto end
start "" "%~dp0Launch.bat"

:end
endlocal
exit /b 0
