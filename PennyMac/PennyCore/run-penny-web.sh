#!/usr/bin/env bash
# Run Penny as a local web app (Swift + MLX) and expose it publicly via a
# Cloudflare quick tunnel, so a remote tester (e.g. on Windows) can use it in a
# browser. All parsing + MLX inference runs on THIS Mac; the tester only needs a
# browser. Ctrl-C stops both the server and the tunnel.
set -euo pipefail
cd "$(dirname "$0")"                      # PennyMac/PennyCore
PORT="${PENNY_PORT:-8088}"
BIN_DIR=".build/debug"

# --local (or PENNY_LOCAL=1): run the server only and open it in this Mac's
# browser — no public Cloudflare tunnel. Default is to expose a public URL.
LOCAL=0
[ "${1:-}" = "--local" ] && LOCAL=1
[ "${PENNY_LOCAL:-0}" = "1" ] && LOCAL=1

echo "▸ Building penny-server…"
swift build --product penny-server

# plain `swift build` does NOT emit MLX's Metal shader library; the Xcode build
# does. Copy that bundle next to our binary so MLX can initialise (else it aborts
# with "Failed to load the default metallib").
METALLIB="$BIN_DIR/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [ ! -e "$METALLIB" ]; then
  SRC="$(find ../.dd ../.dd-rel -name default.metallib -path '*mlx-swift_Cmlx.bundle*' 2>/dev/null | head -1 || true)"
  if [ -n "${SRC:-}" ]; then
    BUNDLE="$(dirname "$(dirname "$(dirname "$SRC")")")"   # → mlx-swift_Cmlx.bundle
    cp -R "$BUNDLE" "$BIN_DIR/"
    echo "▸ Installed MLX Metal library beside the binary."
  else
    echo "⚠ No default.metallib found. Build the Xcode app once to generate it:"
    echo "    (cd .. && xcodebuild -project Penny.xcodeproj -scheme Penny -configuration Debug -derivedDataPath .dd build)"
    echo "  The deterministic app still works; only the on-device model needs this."
  fi
fi

cleanup() { echo; echo "▸ Stopping…"; kill "${SERVER_PID:-}" "${TUNNEL_PID:-}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

echo "▸ Starting server on http://127.0.0.1:$PORT"
env PENNY_PORT="$PORT" "$BIN_DIR/penny-server" &
SERVER_PID=$!
sleep 2

if [ "$LOCAL" = "1" ]; then
  echo
  echo "════════════════════════════════════════════════════════════════"
  echo "  Penny is running locally:  http://127.0.0.1:$PORT"
  echo "  (local-only — no public tunnel). Ctrl-C to stop."
  echo "════════════════════════════════════════════════════════════════"
  command -v open >/dev/null && open "http://127.0.0.1:$PORT" || true
  wait
  exit 0
fi

echo "▸ Opening Cloudflare tunnel…"
TUNNEL_LOG="$(mktemp)"
cloudflared tunnel --url "http://127.0.0.1:$PORT" > "$TUNNEL_LOG" 2>&1 &
TUNNEL_PID=$!

# wait for the public URL
URL=""
for _ in $(seq 1 30); do
  sleep 2
  URL="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" | head -1 || true)"
  [ -n "$URL" ] && break
done

echo
echo "════════════════════════════════════════════════════════════════"
echo "  Local:   http://127.0.0.1:$PORT"
echo "  Public:  ${URL:-<still connecting — check $TUNNEL_LOG>}"
echo "  Share the Public URL with your tester. Ctrl-C to stop."
echo "════════════════════════════════════════════════════════════════"

wait
