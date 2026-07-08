@echo off
echo Stopping Penny (both servers + tunnel)...
for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":5667 " ^| findstr LISTENING') do taskkill /PID %%p /F >nul 2>&1
for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":5668 " ^| findstr LISTENING') do taskkill /PID %%p /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq Penny - tunnel*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq Penny - server*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq Penny 8B Server*" /F >nul 2>&1
taskkill /FI "WINDOWTITLE eq Penny 4B Server*" /F >nul 2>&1
echo Done.
timeout /t 2 /nobreak >nul
