// Lightweight API Worker for ESP32 polling.
// NOT behind Cloudflare Access — authenticated via Bearer token only.

const KV_KEY = "wake_pending";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // ESP32 polling: is there a pending wake?
    if (request.method === "GET" && url.pathname === "/check") {
      return handleCheck(request, env);
    }

    // ESP32 acknowledge: clear the pending wake
    if (request.method === "POST" && url.pathname === "/ack") {
      return handleAck(request, env);
    }

    return new Response("Not Found", { status: 404 });
  },
};

function authenticateEsp32(request, env) {
  const auth = request.headers.get("Authorization") || "";
  const token = auth.replace("Bearer ", "");
  if (!env.ESP32_SECRET || token !== env.ESP32_SECRET) {
    return Response.json({ ok: false, error: "Unauthorized" }, { status: 401 });
  }
  return null;
}

async function handleCheck(request, env) {
  const authErr = authenticateEsp32(request, env);
  if (authErr) return authErr;

  const raw = await env.WAKE_QUEUE.get(KV_KEY);
  if (!raw) {
    return Response.json({ wake: false });
  }

  try {
    const data = JSON.parse(raw);
    return Response.json({ wake: !!data.requested, timestamp: data.timestamp });
  } catch {
    return Response.json({ wake: false });
  }
}

async function handleAck(request, env) {
  const authErr = authenticateEsp32(request, env);
  if (authErr) return authErr;

  await env.WAKE_QUEUE.delete(KV_KEY);
  return Response.json({ ok: true, message: "Acknowledged" });
}
