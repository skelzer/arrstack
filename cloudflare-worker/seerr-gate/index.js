// seerr-gate: transparent auto-wake in front of the Seerr hostname.
//
// Every request is passed through to the origin (the Cloudflare Tunnel on the PC).
// When the tunnel is down because the PC is asleep, Cloudflare answers 530 (error 1033)
// or a 52x. In that case this Worker:
//   1. sets the same `wake_pending` flag the Wake Server page sets (the ESP32 polls it
//      through the wake-api Worker and sends the magic packet),
//   2. optionally posts a Telegram note,
//   3. serves a "waking up" page that polls until Seerr answers, then reloads.
// Runs behind the same Cloudflare Access policy as the hostname, so only allowed users
// can trigger a wake by visiting.

const KV_KEY = "wake_pending";
const REARM_AFTER_MS = 5 * 60 * 1000; // re-set a stale flag if the PC still isn't up after 5 min
const DOWN_STATUSES = new Set([530, 521, 522, 523, 524]);

export default {
  async fetch(request, env, ctx) {
    let origin;
    try {
      origin = await fetch(request);
    } catch (err) {
      origin = new Response("origin fetch failed: " + err.message, { status: 523 });
    }

    if (!DOWN_STATUSES.has(origin.status)) {
      return origin; // PC is up: behave as if this Worker did not exist
    }

    // Origin is unreachable: queue a wake (once) and show the waiting page.
    ctx.waitUntil(queueWake(env));

    if (request.method !== "GET" && request.method !== "HEAD") {
      return Response.json(
        { ok: false, error: "Media server is waking up, retry in a minute." },
        { status: 503, headers: { "Retry-After": "60", "X-Seerr-Gate": "waking" } }
      );
    }
    return new Response(WAITING_PAGE, {
      status: 503,
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        "Retry-After": "30",
        "X-Seerr-Gate": "waking",
      },
    });
  },
};

async function queueWake(env) {
  try {
    const raw = await env.WAKE_QUEUE.get(KV_KEY);
    if (raw) {
      const data = JSON.parse(raw);
      if (Date.now() - (data.timestamp || 0) < REARM_AFTER_MS) return; // already pending, don't spam
    }
    await env.WAKE_QUEUE.put(KV_KEY, JSON.stringify({ requested: true, timestamp: Date.now(), source: "seerr-gate" }));

    const { TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID } = env;
    if (TELEGRAM_BOT_TOKEN && TELEGRAM_CHAT_ID) {
      await fetch(`https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ chat_id: TELEGRAM_CHAT_ID, text: "[arrstack] Someone opened Seerr while the server was asleep. Wake queued." }),
      }).catch(() => {});
    }
  } catch (err) {
    console.log("queueWake failed: " + err.message);
  }
}

const WAITING_PAGE = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Waking the media server</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f0f0f; color: #e0e0e0;
           display: flex; align-items: center; justify-content: center; min-height: 100dvh; padding: 1rem; }
    .card { background: #1a1a1a; border: 1px solid #2a2a2a; border-radius: 16px; padding: 2.5rem 2rem; text-align: center;
            max-width: 360px; width: 100%; box-shadow: 0 8px 32px rgba(0,0,0,.4); }
    h1 { font-size: 1.4rem; font-weight: 600; margin-bottom: .4rem; color: #fff; }
    p { font-size: .9rem; color: #888; line-height: 1.5; }
    .spinner { width: 40px; height: 40px; margin: 1.5rem auto; border: 3px solid #2a2a2a; border-top-color: #2563eb;
               border-radius: 50%; animation: spin 1s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
    #status { margin-top: 1rem; font-size: .85rem; color: #facc15; min-height: 1.4em; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Waking the media server</h1>
    <p>The PC was asleep. A wake signal has been sent; this page will open Seerr by itself once it is up. Usually under two minutes.</p>
    <div class="spinner"></div>
    <p id="status">Checking…</p>
  </div>
  <script>
    const started = Date.now();
    async function check() {
      const s = document.getElementById("status");
      try {
        const r = await fetch(location.href, { cache: "no-store", redirect: "manual" });
        if (r.ok || r.type === "opaqueredirect" || (r.status >= 300 && r.status < 400)) {
          if (r.headers.get("X-Seerr-Gate") !== "waking") { s.textContent = "Server is up, loading Seerr…"; location.reload(); return; }
        }
      } catch (e) {}
      const mins = Math.floor((Date.now() - started) / 60000);
      s.textContent = mins < 3 ? "Still waking… " + mins + " min" : "Taking longer than usual. The wake page is the manual fallback.";
      setTimeout(check, 10000);
    }
    setTimeout(check, 10000);
  </script>
</body>
</html>`;
