# penny-categories-server

The **central categories API** for Penny. It hosts Penny's categorization
vocabulary — the `merchant_map` + keyword `category_rules` from `categories.json`
— so **every device fetches the same, always-current categories over HTTP**,
instead of each build baking in its own copy. Improve a category once on the
server and every installed app picks it up; no new release needed.

```
Penny app ──GET /v1/categories──▶ penny-categories-server ──▶ categories.json
```

- Port: **8999**
- Hosted at: **https://penny1.thescript.design**
- Dependency-free (Node 18+ built-ins only).

## Endpoints

| Method | Path | Purpose |
| ------ | ---- | ------- |
| GET | `/` or `/health` | health check → `penny-categories ok` |
| GET | `/v1/categories` (alias `/categories`) | the categories payload (see below). Honours `If-None-Match` → `304` |
| POST | `/v1/categories` | replace hosted categories (token-gated) |
| POST | `/v1/messages` | **optional** Anthropic proxy passthrough, on only if `ANTHROPIC_API_KEY` is set |

### GET payload

```json
{
  "version": "a1b2c3d4",
  "etag": "\"a1b2c3d4...\"",
  "categories": ["Cash", "Education", "Entertainment", "..."],
  "merchant_map": { "swiggy": ["Swiggy", "Food & Dining"], "...": [] },
  "category_rules": [["Food & Dining", ["swiggy", "zomato"]], ["..."]]
}
```

`categories` is the flat, de-duped, sorted list of canonical category names — use
it for pickers/filters. `merchant_map` + `category_rules` are the full
deterministic vocabulary the parser consumes (byte-identical to the app's bundled
`categories.json`).

## Run

```bash
cd penny-categories-server
cp .env.example .env        # set APP_TOKEN (and optionally ANTHROPIC_API_KEY)
./run.sh                    # server on :8999
./run.sh --tunnel           # + a cloudflared quick tunnel (prints a temp URL)
```

Or manually: `PORT=8999 node --env-file=.env server.js`.

### Stable hostname (penny1.thescript.design)

Use a **named** Cloudflare tunnel (one-time):

```bash
cloudflared tunnel login
cloudflared tunnel create penny1
cloudflared tunnel route dns penny1 penny1.thescript.design
cloudflared tunnel run --url http://localhost:8999 penny1
```

## Update the hosted categories

```bash
curl -sS https://penny1.thescript.design/v1/categories \
  -X POST -H "authorization: Bearer $APP_TOKEN" \
  -H "content-type: application/json" \
  --data @categories.json
```

Body is a full `categories.json` (`{ merchant_map, category_rules }`). The server
validates, persists it to disk, and refreshes immediately — the next `GET` (and
every device) sees the new version.

> Per project convention, category **fixes/gaps still flow through the Claude API
> pipeline**, not hand-edited vocab. This endpoint is how that pipeline (or an
> operator) publishes an updated `categories.json` to all devices centrally.

## Point the app at it

In `PennyMac/PennyApp/AppModel.swift`, `PennyBackend`:

```swift
static let host = "https://penny1.thescript.design"
static let categoriesURL = URL(string: host + "/v1/categories")
```

The app fetches on launch, caches to Application Support, and the deterministic
ingester prefers the cached server copy over the bundled one (falling back to
bundled if the fetch has never succeeded — so it works fully offline).

## Verify

```bash
curl https://penny1.thescript.design/health                 # penny-categories ok
curl -s https://penny1.thescript.design/v1/categories | head
```

## Notes

- **Reads are open** (so every device can fetch); **writes need `APP_TOKEN`**.
  A per-IP rate limiter guards the open read endpoint.
- `APP_TOKEN` is not a hard secret if it ships in the app binary — it stops
  casual abuse and can be rotated. Writes are the sensitive path; keep that token
  server-side / operator-only.
- Setting `ANTHROPIC_API_KEY` makes this one host serve **both** categories and
  the categorization proxy, replacing the separate `penny-proxy/` deployment.
