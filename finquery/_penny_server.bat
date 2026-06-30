@echo off
title Penny - server (port 5667)
cd /d "%~dp0"
set "FINQ_DB=%~dp0data\live_txn.db"
set "PYTHONIOENCODING=utf-8"
set "PORT=5667"
:loop
echo [%date% %time%] starting Penny server on http://127.0.0.1:5667 ...
python scripts\test_server.py
echo [%date% %time%] server stopped - restarting in 3s. Close this window to stop.
timeout /t 3 /nobreak >nul
goto loop
