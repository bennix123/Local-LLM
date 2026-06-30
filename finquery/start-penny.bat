@echo off
setlocal
cd /d "%~dp0"
echo ============================================================
echo    Penny  -  starting server + permanent tunnel
echo ============================================================

REM --- free port 5667 if something is already listening ---
for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":5667 " ^| findstr LISTENING') do (
  echo Freeing port 5667 ^(PID %%p^)...
  taskkill /PID %%p /F >nul 2>&1
)

REM --- start the server in its own auto-restarting window ---
start "Penny server" cmd /c _penny_server.bat

REM --- wait until the server answers on :5667 ---
echo Waiting for server to come up...
:wait
timeout /t 1 /nobreak >nul
curl -s -o nul http://127.0.0.1:5667/status
if errorlevel 1 goto wait
echo Server is up.

REM --- start the fixed-URL tunnel in its own auto-reconnecting window ---
start "Penny tunnel" cmd /c _penny_tunnel.bat

echo.
echo ============================================================
echo    Penny is live at:
echo.
echo        https://penny-finance.loca.lt
echo.
echo    First visit shows a one-time loca.lt click-through page.
echo    If the tunnel window shows a DIFFERENT "your url is",
echo    that name was taken - use the url it prints instead.
echo    Leave the two opened windows running; close them to stop
echo    (or run stop-penny.bat).
echo ============================================================
echo.

REM --- open the app in the default browser ---
timeout /t 5 /nobreak >nul
start "" https://penny-finance.loca.lt
endlocal
