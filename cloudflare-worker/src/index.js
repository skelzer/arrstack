export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/") {
      return new Response(HTML_PAGE, {
        headers: { "Content-Type": "text/html; charset=utf-8" },
      });
    }

    if (request.method === "POST" && url.pathname === "/wake") {
      return handleWake(env);
    }

    return new Response("Not Found", { status: 404 });
  },
};

async function handleWake(env) {
  const { TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID } = env;

  if (!TELEGRAM_BOT_TOKEN || !TELEGRAM_CHAT_ID) {
    return Response.json(
      { ok: false, error: "Server misconfigured: missing Telegram secrets." },
      { status: 500 }
    );
  }

  try {
    const telegramUrl = `https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage`;

    const res = await fetch(telegramUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chat_id: TELEGRAM_CHAT_ID,
        text: "/wake",
      }),
    });

    const data = await res.json();

    if (!data.ok) {
      return Response.json(
        { ok: false, error: `Telegram API error: ${data.description}` },
        { status: 502 }
      );
    }

    return Response.json({ ok: true, message: "Wake command sent!" });
  } catch (err) {
    return Response.json(
      { ok: false, error: `Request failed: ${err.message}` },
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
    <p class="subtitle">Send a Wake-on-LAN magic packet to the media server.</p>
    <button id="wakeBtn" onclick="wake()">Wake Server</button>
    <p id="status" class="status"></p>
  </div>
  <script>
    async function wake() {
      const btn    = document.getElementById("wakeBtn");
      const status = document.getElementById("status");

      btn.disabled = true;
      btn.textContent = "Sending...";
      status.textContent = "Sending wake command...";
      status.className = "status pending";

      try {
        const res  = await fetch("/wake", { method: "POST" });
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

      btn.textContent = "Wake Server";
      btn.disabled = false;
    }
  </script>
</body>
</html>`;
