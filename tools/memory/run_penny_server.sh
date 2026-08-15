#!/usr/bin/env bash
# Start the Penny MLX web server (conversation-aware memory + context-LoRA).
# The Node app (server.js) proxies to it when the UI "🧠 Memory" toggle is on.
set -e
cd "$(dirname "$0")"
exec ../../.venv-mlx/bin/python penny_server.py
