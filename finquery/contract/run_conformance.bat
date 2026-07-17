@echo off
REM Penny contract conformance - Windows runner.
REM Creates an isolated venv, installs the two parsing deps, and runs the
REM 15-fixture exact-match suite against a throwaway database.
REM No LLM needed: mlx-lm cannot load on Windows, so the pipeline runs the
REM deterministic path the *_expected.json fixtures were generated with.

setlocal
cd /d "%~dp0.."

if not exist .venv-conformance (
    python -m venv .venv-conformance || goto :fail
)
call .venv-conformance\Scripts\activate.bat

python -m pip install --quiet --disable-pip-version-check pymupdf jsonschema || goto :fail

set TXN_DB_PATH=%TEMP%\penny_conformance.db
if exist "%TXN_DB_PATH%" del /q "%TXN_DB_PATH%"

python contract\conformance.py %*
set RC=%ERRORLEVEL%
exit /b %RC%

:fail
echo.
echo [ERROR] Setup failed. Check that Python 3.10+ is installed and on PATH.
exit /b 1
