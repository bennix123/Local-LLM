# Categorizer: switching between cloud and local

The app's categorization (DeepSeek) goes through the **penny-categories-server**
proxy in this folder. The API key lives ONLY on the server — never in the app.

The app picks its server in this order (`PennyMac/PennyApp/AppModel.swift`,
`PennyBackend.host`):

1. `PENNY_BACKEND_HOST` environment variable (Xcode scheme), if set
2. `PennyBackendHost` user default, if set
3. the hosted default: `https://penny1.thescript.design`

**Switching needs NO code change** — it's one terminal command.

## Cloud → local (develop/test against your own machine)

```bash
# 1. Start the server (reads the key from .env in this folder):
cd penny-categories-server && ./run.sh

# 2. Point the app at it, then relaunch Penny:
defaults write com.localbankrag.app PennyBackendHost "http://127.0.0.1:8999"
```

`.env` needs (gitignored, never commit):

```
DEEPSEEK_API_KEY=sk-…
APP_TOKEN=02395bd2d19b6307e8c58216e9375254c578bae8f2eed4b5e851cfb8de50dcb8
PORT=8999
```

`APP_TOKEN` must equal `PennyBackend.appToken` in `AppModel.swift`.
For another device on your Wi-Fi (a phone, a second Mac), use your Mac's LAN
IP instead of 127.0.0.1: `ipconfig getifaddr en0`.

## Local → cloud (back to the hosted server)

```bash
defaults delete com.localbankrag.app PennyBackendHost
```

Relaunch Penny. It falls back to `https://penny1.thescript.design`.

## TestFlight / other people's devices

Overrides are per-machine, so TestFlight users always get the hosted default.
That means **a server must actually be running behind
penny1.thescript.design** — as of 2026-08-29 the tunnel answers 530 (tunnel
up, server behind it down). To revive it, on the hosting machine:

```bash
cd penny-categories-server && ./run.sh          # server on :8999 (needs .env)
cloudflared tunnel run --url http://localhost:8999 penny1   # named tunnel
```

(One-time tunnel setup commands are documented at the top of `run.sh`.)
Health check from anywhere: `curl https://penny1.thescript.design/health`
→ should print `penny-categories ok`.

## The ONE code line that ever changes

If the hosted domain itself moves (new server, new name), edit the fallback
in `PennyMac/PennyApp/AppModel.swift` → `PennyBackend.host`:

```swift
return "https://penny1.thescript.design"   // ← replace this URL only
```

Rebuild, and verify with a round-trip before shipping:

```bash
curl -X POST https://NEW-HOST/v1/messages \
  -H "Authorization: Bearer <APP_TOKEN>" -H "content-type: application/json" \
  -d '{"model":"claude-sonnet-5","max_tokens":20,"messages":[{"role":"user","content":"Reply with exactly: OK"}]}'
```
