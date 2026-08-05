# penny-proxy

Why this exists: Penny categorizes transactions **only** via the Anthropic API.
The app looks for a key in `ANTHROPIC_API_KEY` (your Xcode run) or the Keychain.
A **TestFlight build has neither**, so the categorization pass silently no-ops and
every merchant stays **"Other"** — exactly the bug testers reported.

This proxy holds the real Anthropic key **server-side** and forwards requests, so
the app categorizes for everyone with no per-user key.

```
Penny app ──POST /v1/messages (Bearer APP_TOKEN)──▶ penny-proxy ──x-api-key──▶ api.anthropic.com
```

It's a transparent pass-through: the app already sends a valid Anthropic
`/v1/messages` body; the proxy only adds authentication.

## Pick ONE deployment

### A. Cloudflare Worker (recommended — always-on, no server to babysit)

```bash
cd penny-proxy
npx wrangler login
npx wrangler secret put ANTHROPIC_API_KEY   # paste sk-ant-...
npx wrangler secret put APP_TOKEN           # paste a long random string
npx wrangler deploy
```

Deploy prints a URL like `https://penny-proxy.<you>.workers.dev`.

### B. Node service (behind your existing Cloudflare tunnel, or any host)

```bash
cd penny-proxy
cp .env.example .env        # fill in ANTHROPIC_API_KEY + APP_TOKEN
node --env-file=.env server.js
# then expose it, e.g. with the tunnel you already use:
#   cloudflared tunnel --url http://localhost:8787
```

Node 18+ required (uses the built-in `fetch`).

## Point the app at it

In `PennyMac/PennyApp/AppModel.swift`, set `PennyBackend`:

```swift
enum PennyBackend {
    static let urlString = "https://penny-proxy.<you>.workers.dev/v1/messages"  // note the /v1/messages
    static let appToken  = "the-same-long-random-string-you-set-as-APP_TOKEN"
}
```

Rebuild and ship. Testers now categorize with no key of their own. A developer
who still has `ANTHROPIC_API_KEY` set (or a Keychain key) keeps talking to
Anthropic directly — the proxy is only used when there's no personal key.

## Verify

```bash
# Health:
curl https://<your-proxy>/                       # -> penny-proxy ok

# End-to-end (should return an Anthropic JSON message, not 401/404):
curl -sS https://<your-proxy>/v1/messages \
  -H "authorization: Bearer $APP_TOKEN" \
  -H "content-type: application/json" \
  -d '{"model":"claude-haiku-4-5","max_tokens":16,"messages":[{"role":"user","content":"ping"}]}'
```

## Notes / hardening

- **APP_TOKEN is not a hard secret** — it ships inside the app binary and can be
  extracted. It stops casual abuse and lets you revoke old builds by rotating it.
  The Node build also rate-limits per IP (`LIMIT`/`WINDOW_MS` in `server.js`).
- **Cost is yours now.** Every tester's categorization bills your Anthropic
  account. Watch usage in the Anthropic console; set a spend limit.
- The proxy forwards whatever model the app asks for (currently
  `claude-sonnet-5`). To cap cost you can rewrite `model` in the body before
  forwarding.
