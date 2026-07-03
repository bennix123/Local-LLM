#!/bin/zsh
# Penny server launcher (macOS) — mirrors _penny_server.bat.
# SSL_CERT_FILE points python.org Python at certifi's CA bundle (needed for Plaid).
cd "$(dirname "$0")"
export PORT="${PORT:-5667}"
export SSL_CERT_FILE="$(.venv/bin/python -c 'import certifi; print(certifi.where())')"
echo "starting Penny on http://127.0.0.1:$PORT ..."
exec .venv/bin/python scripts/test_server.py
