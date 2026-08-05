// penny-proxy — Cloudflare Worker variant of server.js. Same job: hold the real
// Anthropic key server-side and forward `/v1/messages` for the Penny app.
//
// Deploy:
//   cd penny-proxy
//   npx wrangler secret put ANTHROPIC_API_KEY      # paste your sk-ant-... key
//   npx wrangler secret put APP_TOKEN              # paste the shared app token
//   npx wrangler deploy
// The deployed URL + "/v1/messages" is what goes in PennyBackend.urlString.

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "GET" && (url.pathname === "/" || url.pathname === "/health")) {
      return new Response("penny-proxy ok");
    }
    if (request.method !== "POST" || !url.pathname.startsWith("/v1/messages")) {
      return json({ error: "not_found" }, 404);
    }

    // Optional shared-token gate (rotate the secret to revoke old builds).
    if (env.APP_TOKEN) {
      const auth = request.headers.get("authorization") || "";
      if (auth !== `Bearer ${env.APP_TOKEN}`) return json({ error: "unauthorized" }, 401);
    }

    const body = await request.text();
    try {
      const upstream = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-api-key": env.ANTHROPIC_API_KEY,
          "anthropic-version": request.headers.get("anthropic-version") || "2023-06-01",
        },
        body,
      });
      return new Response(await upstream.text(), {
        status: upstream.status,
        headers: { "content-type": "application/json" },
      });
    } catch (e) {
      return json({ error: "upstream_error", message: String((e && e.message) || e) }, 502);
    }
  },
};

function json(obj, status) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}
