// Lightweight API Worker for ESP32 polling.
// NOT behind Cloudflare Access — authenticated via Bearer token only.

// Single KV key holds an object of pending wakes: { "<target>": <timestamp>, ... }
const KV_KEY = "wake_pending";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // ESP32 polling: which targets have a pending wake?
    if (request.method === "GET" && url.pathname === "/check") {
      return handleCheck(request, env);
    }

    // ESP32 acknowledge: clear a target's pending wake
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

async function readPending(env) {
  const raw = await env.WAKE_QUEUE.get(KV_KEY);
  if (!raw) return {};
  try {
    const data = JSON.parse(raw);
    // Object form: { target: timestamp }
    return data && typeof data === "object" ? data : {};
  } catch {
    return {};
  }
}

async function handleCheck(request, env) {
  const authErr = authenticateEsp32(request, env);
  if (authErr) return authErr;

  const pending = await readPending(env);
  const targets = Object.keys(pending);

  // `wake` kept for convenience: true if anything is pending.
  return Response.json({ wake: targets.length > 0, targets });
}

async function handleAck(request, env) {
  const authErr = authenticateEsp32(request, env);
  if (authErr) return authErr;

  let target = null;
  try {
    const body = await request.json();
    target = body && body.target ? String(body.target) : null;
  } catch {
    // no/invalid body — fall through
  }

  const pending = await readPending(env);

  if (!target) {
    // No target specified: clear everything (back-compat).
    await env.WAKE_QUEUE.delete(KV_KEY);
    return Response.json({ ok: true, message: "Acknowledged all" });
  }

  delete pending[target];
  if (Object.keys(pending).length === 0) {
    await env.WAKE_QUEUE.delete(KV_KEY);
  } else {
    await env.WAKE_QUEUE.put(KV_KEY, JSON.stringify(pending));
  }

  return Response.json({ ok: true, message: `Acknowledged ${target}` });
}
