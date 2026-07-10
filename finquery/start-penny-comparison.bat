@echo off
setlocal
cd /d "%~dp0"
echo ============================================================
echo    Penny  -  Starting Llama 8B and Qwen 3B Servers for Comparison
echo ============================================================

REM --- free port 5667 if something is already listening ---
for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":5667 " ^| findstr LISTENING') do (
  echo Freeing port 5667 ^(PID %%p^)...
  taskkill /PID %%p /F >nul 2>&1
)

REM --- free port 5668 if something is already listening ---
for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":5668 " ^| findstr LISTENING') do (
  echo Freeing port 5668 ^(PID %%p^)...
  taskkill /PID %%p /F >nul 2>&1
)

REM --- start the 8B server (default port 5667) ---
echo Starting 8B server (Llama 3.1 8B) on port 5667...
start "Penny 8B Server" cmd /c _penny_server_llama8b.bat

REM --- start the 3B server (port 5668) ---
echo Starting 3B server (Qwen 3B) on port 5668...
start "Penny Qwen 3B Server" cmd /c _penny_server_qwen3b.bat

REM --- wait until 8B server answers on :5667 ---
echo Waiting for 8B server (port 5667) to come up...
:wait8b
ping 127.0.0.1 -n 2 >nul
curl -s -o nul http://127.0.0.1:5667/status
if errorlevel 1 goto wait8b
echo 8B Server is up.

REM --- wait until 3B server answers on :5668 ---
echo Waiting for 3B server (port 5668) to come up...
:wait3b
ping 127.0.0.1 -n 2 >nul
curl -s -o nul http://127.0.0.1:5668/status
if errorlevel 1 goto wait3b
echo 3B Server is up.

echo.
echo ============================================================
echo    Comparison is ready!
echo.
echo    Llama 3.1 8B (Port 5667):   http://127.0.0.1:5667/app
echo    Qwen 2.5 3B (Port 5668):    http://127.0.0.1:5668/app
echo.
echo    You can open both URLs in side-by-side browser tabs.
echo    Run stop-penny.bat to stop both servers.
echo ============================================================
echo.

REM --- open the apps in the default browser ---
ping 127.0.0.1 -n 3 >nul
start "" http://127.0.0.1:5667/app
start "" http://127.0.0.1:5668/app
endlocal
