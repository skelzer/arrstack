// Lightweight API Worker for the ESP32 (wake polling) and the media server PC
// (status pushes). NOT behind Cloudflare Access — authenticated via Bearer token only.

// Single KV key holds an object of pending wakes: { "<target>": <timestamp>, ... }
const KV_KEY = "wake_pending";

// Latest status pushed by the PC (free space, now playing). It expires by itself when
// the pushes stop (PC asleep), which the display reads as "asleep".
const STATUS_KEY = "server_status";
const STATUS_TTL_S = 600;
const MAX_PLAYING = 3;
const MAX_TITLE_CHARS = 40;

// Now-playing poster (60x90 baseline JPEG, pushed base64 by the PC). Kept in its own
// key so /check stays small; the ESP32 fetches /poster only when `poster_id` changes.
const POSTER_KEY = "server_poster";
const POSTER_MAX_B64 = 40 * 1024;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // ESP32 polling: which targets have a pending wake, plus the latest server status
    if (request.method === "GET" && url.pathname === "/check") {
      return handleCheck(request, env);
    }

    // ESP32 acknowledge: clear a target's pending wake
    if (request.method === "POST" && url.pathname === "/ack") {
      return handleAck(request, env);
    }

    // PC status push (mediaserver/status-push.ps1)
    if (request.method === "POST" && url.pathname === "/status") {
      return handleStatusPush(request, env);
    }

    // ESP32: current now-playing poster as raw JPEG
    if (request.method === "GET" && url.pathname === "/poster") {
      return handlePoster(request, env);
    }

    return new Response("Not Found", { status: 404 });
  },
};

function authenticateBearer(request, env) {
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
    if (!data || typeof data !== "object") return {};
    // Legacy single-flag shape ({ requested: true, timestamp }) from an older
    // writer -> treat as a pending "server" wake.
    if (data.requested === true) {
      return { server: data.timestamp || Date.now() };
    }
    // Object form: { target: timestamp }
    return data;
  } catch {
    return {};
  }
}

async function readStatus(env) {
  const raw = await env.WAKE_QUEUE.get(STATUS_KEY);
  if (!raw) return null;
  try {
    const status = JSON.parse(raw);
    if (!status || typeof status !== "object") return null;
    // Age computed here so the ESP32 needs no clock of its own.
    status.age_s = Math.max(0, Math.round((Date.now() - (status.received || 0)) / 1000));
    return status;
  } catch {
    return null;
  }
}

async function handleCheck(request, env) {
  const authErr = authenticateBearer(request, env);
  if (authErr) return authErr;

  const [pending, status] = await Promise.all([readPending(env), readStatus(env)]);
  const targets = Object.keys(pending);

  // `wake` kept for convenience: true if anything is pending.
  return Response.json({ wake: targets.length > 0, targets, status });
}

async function handleAck(request, env) {
  const authErr = authenticateBearer(request, env);
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

// Body: { free: { "F": <GB>, "D": <GB> }, playing: [{ title, user }, ...] }
async function handleStatusPush(request, env) {
  const authErr = authenticateBearer(request, env);
  if (authErr) return authErr;

  let body = null;
  try {
    body = await request.json();
  } catch {
    // handled below
  }
  if (!body || typeof body !== "object") {
    return Response.json({ ok: false, error: "Invalid JSON body" }, { status: 400 });
  }

  // Keep only well-formed, bounded data: this is what the ESP32 has to parse.
  const free = {};
  for (const [drive, gb] of Object.entries(body.free || {})) {
    if (typeof gb === "number" && Number.isFinite(gb)) free[drive] = Math.round(gb);
  }
  const playing = (Array.isArray(body.playing) ? body.playing : [])
    .slice(0, MAX_PLAYING)
    .map((p) => ({
      title: String((p && p.title) || "").slice(0, MAX_TITLE_CHARS),
      user: String((p && p.user) || "").slice(0, 20),
    }));

  // Poster: only accept a plausible JPEG, and only write it when the item changed
  // (KV writes are the scarce resource on the free plan).
  let posterId = typeof body.poster_id === "string" ? body.poster_id.slice(0, 64) : "";
  let posterBytes = null;
  if (posterId && typeof body.poster === "string" && body.poster.length <= POSTER_MAX_B64) {
    try {
      const bytes = base64ToBytes(body.poster);
      if (bytes.length > 4 && bytes[0] === 0xff && bytes[1] === 0xd8) posterBytes = bytes; // JPEG SOI
    } catch {
      // bad base64: treat as no poster
    }
  }
  if (!posterBytes) posterId = "";

  const prev = await readStatus(env);
  const prevPosterId = (prev && prev.poster_id) || "";

  const writes = [
    env.WAKE_QUEUE.put(
      STATUS_KEY,
      JSON.stringify({ free, playing, poster_id: posterId, received: Date.now() }),
      { expirationTtl: STATUS_TTL_S }
    ),
  ];
  if (posterBytes && posterId !== prevPosterId) {
    writes.push(env.WAKE_QUEUE.put(POSTER_KEY, posterBytes.buffer, { expirationTtl: STATUS_TTL_S }));
  } else if (!posterBytes && prevPosterId) {
    writes.push(env.WAKE_QUEUE.delete(POSTER_KEY));
  }
  await Promise.all(writes);
  return Response.json({ ok: true });
}

async function handlePoster(request, env) {
  const authErr = authenticateBearer(request, env);
  if (authErr) return authErr;

  const buf = await env.WAKE_QUEUE.get(POSTER_KEY, "arrayBuffer");
  if (!buf) return new Response("No poster", { status: 404 });
  return new Response(buf, {
    headers: { "Content-Type": "image/jpeg", "Cache-Control": "no-store" },
  });
}

function base64ToBytes(b64) {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
