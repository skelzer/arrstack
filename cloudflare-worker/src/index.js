// Single KV key holds an object of pending wakes: { "<target>": <timestamp>, ... }
const KV_KEY = "wake_pending";

// Machines that can be woken. `id` must match a target id in the ESP32 config.
const TARGETS = [
  { id: "server",  label: "Media Server" },
  { id: "desktop", label: "Desktop (this PC)" },
];

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Web UI (protected by Cloudflare Access)
    if (request.method === "GET" && url.pathname === "/") {
      return new Response(HTML_PAGE, {
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    }

    // Web button: queue a wake request into KV
    if (request.method === "POST" && url.pathname === "/wake") {
      return handleWake(request, env);
    }

    return new Response("Not Found", { status: 404 });
  },
};

async function handleWake(request, env) {
  try {
    // Which machine? Default to "server" for back-compat.
    let target = "server";
    try {
      const body = await request.json();
      if (body && body.target) target = String(body.target);
    } catch {
      // no/invalid body — use default
    }

    if (!TARGETS.some((t) => t.id === target)) {
      return Response.json(
        { ok: false, error: `Unknown target: ${target}` },
        { status: 400 }
      );
    }

    // Merge into the pending object so multiple machines can be queued at once.
    const raw = await env.WAKE_QUEUE.get(KV_KEY);
    let pending = {};
    if (raw) {
      try {
        const parsed = JSON.parse(raw);
        if (parsed && typeof parsed === "object") pending = parsed;
      } catch {
        // ignore corrupt value, start fresh
      }
    }
    pending[target] = Date.now();
    await env.WAKE_QUEUE.put(KV_KEY, JSON.stringify(pending));

    const label = TARGETS.find((t) => t.id === target).label;

    // Notify via Telegram so the user sees confirmation
    const { TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID } = env;
    if (TELEGRAM_BOT_TOKEN && TELEGRAM_CHAT_ID) {
      fetch(`https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          chat_id: TELEGRAM_CHAT_ID,
          text: `Web wake requested for ${label} — waiting for ESP32 to pick it up.`,
        }),
      }).catch(() => {});
    }

    return Response.json({ ok: true, message: `Wake queued for ${label}!` });
  } catch (err) {
    return Response.json(
      { ok: false, error: `Failed to queue wake: ${err.message}` },
      { status: 500 }
    );
  }
}

const HTML_PAGE = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Wake Server</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #0f0f0f;
      color: #e0e0e0;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100dvh;
      padding: 1rem;
    }

    .card {
      background: #1a1a1a;
      border: 1px solid #2a2a2a;
      border-radius: 16px;
      padding: 2.5rem 2rem;
      text-align: center;
      max-width: 360px;
      width: 100%;
      box-shadow: 0 8px 32px rgba(0, 0, 0, 0.4);
    }

    h1 {
      font-size: 1.4rem;
      font-weight: 600;
      margin-bottom: 0.4rem;
      color: #ffffff;
    }

    .subtitle {
      font-size: 0.85rem;
      color: #888;
      margin-bottom: 2rem;
    }

    .buttons {
      display: flex;
      flex-direction: column;
      gap: 0.75rem;
    }

    button {
      width: 100%;
      padding: 1rem;
      font-size: 1.1rem;
      font-weight: 600;
      border: none;
      border-radius: 12px;
      cursor: pointer;
      transition: background 0.2s, transform 0.1s;
      background: #2563eb;
      color: #fff;
    }

    button:hover { background: #1d4ed8; }
    button:active { transform: scale(0.97); }

    button:disabled {
      background: #333;
      color: #666;
      cursor: not-allowed;
      transform: none;
    }

    .status {
      margin-top: 1.2rem;
      font-size: 0.9rem;
      min-height: 1.4em;
      transition: color 0.3s;
    }

    .status.success { color: #4ade80; }
    .status.error   { color: #f87171; }
    .status.pending  { color: #facc15; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Wake Server</h1>
    <p class="subtitle">Send a Wake-on-LAN magic packet to a machine.</p>
    <div class="buttons">
      <button data-target="server"  data-label="Media Server"      onclick="wake(this)">Wake Media Server</button>
      <button data-target="desktop" data-label="Desktop (this PC)" onclick="wake(this)">Wake Desktop</button>
    </div>
    <p id="status" class="status"></p>
  </div>
  <script>
    async function wake(btn) {
      const status = document.getElementById("status");
      const all    = document.querySelectorAll("button");
      const target = btn.dataset.target;
      const label  = btn.dataset.label;
      const original = btn.textContent;

      all.forEach((b) => (b.disabled = true));
      btn.textContent = "Sending...";
      status.textContent = "Sending wake command to " + label + "...";
      status.className = "status pending";

      try {
        const res  = await fetch("/wake", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ target }),
        });
        const data = await res.json();

        if (data.ok) {
          status.textContent = data.message;
          status.className = "status success";
        } else {
          status.textContent = data.error || "Something went wrong.";
          status.className = "status error";
        }
      } catch (err) {
        status.textContent = "Network error: " + err.message;
        status.className = "status error";
      }

      btn.textContent = original;
      all.forEach((b) => (b.disabled = false));
    }
  </script>
</body>
</html>`;
