#!/usr/bin/env bash
# Start penny-categories-server on :8999 and (optionally) expose it at
# https://penny1.thescript.design via a Cloudflare tunnel.
#
#   ./run.sh              # server only, on :8999
#   ./run.sh --tunnel     # server + quick cloudflared tunnel (prints a URL)
#
# For the STABLE penny1.thescript.design hostname use a *named* tunnel with a DNS
# route (one-time setup), not the quick tunnel:
#   cloudflared tunnel login
#   cloudflared tunnel create penny1
#   cloudflared tunnel route dns penny1 penny1.thescript.design
#   cloudflared tunnel run --url http://localhost:8999 penny1
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8999}"
export PORT

if [[ -f .env ]]; then
  echo "▶ starting penny-categories-server on :$PORT (with .env)"
  node --env-file=.env server.js &
else
  echo "▶ starting penny-categories-server on :$PORT (no .env — reads/health only unless env vars are exported)"
  node server.js &
fi
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

# Give the listener a moment, then health-check.
sleep 1
curl -sf "http://localhost:$PORT/health" && echo "  ✓ health ok" || echo "  ✗ health check failed"

if [[ "${1:-}" == "--tunnel" ]]; then
  if ! command -v cloudflared >/dev/null 2>&1; then
    echo "cloudflared not installed — 'brew install cloudflared'. Running server only."
    wait $SERVER_PID
  fi
  echo "▶ opening cloudflared quick tunnel → http://localhost:$PORT"
  cloudflared tunnel --url "http://localhost:$PORT"
else
  wait $SERVER_PID
fi
