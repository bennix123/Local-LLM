@echo off
echo Stopping Penny (server + tunnel)...
for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":5667 " ^| findstr LISTENING') do taskkill /PID %%p /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq Penny - tunnel*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq Penny - server*" /F >nul 2>&1
echo Done. (If a tunnel window is still open, close it manually.)
timeout /t 2 /nobreak >nul
