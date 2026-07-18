@echo off
title Penny - online server (port 5669)
cd /d "%~dp0"
set "FINQ_DB=%~dp0data\live_txn.db"
set "PYTHONIOENCODING=utf-8"
set "PORT=5669"
set "LLM_PROVIDER=groq"
set "LLM_MODEL=llama-3.1-8b-instant"
:loop
echo [%date% %time%] starting Penny Online Groq server on http://127.0.0.1:5669 with model %LLM_MODEL% ...
python scripts\test_server.py
echo [%date% %time%] server stopped - restarting in 3s. Close this window to stop.
ping 127.0.0.1 -n 4 >nul
goto loop
