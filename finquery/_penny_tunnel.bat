@echo off
title Penny - tunnel (penny-finance.loca.lt)
cd /d "%~dp0"
:loop
echo [%date% %time%] connecting permanent tunnel https://penny-finance.loca.lt ...
call npx --yes localtunnel --port 5667 --subdomain penny-finance
echo [%date% %time%] tunnel dropped - reconnecting in 3s. Close this window to stop.
timeout /t 3 /nobreak >nul
goto loop
