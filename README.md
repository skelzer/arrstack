# Remote Wake-on-LAN & *arr Stack Access

Remotely wake a media server PC and securely access services (Seerr) without port forwarding, plus the Docker *arr stack that runs on it and the scripts that keep it tidy.

## How It Works

1. **Wake** -- A Cloudflare Worker (`wake-server`, behind Cloudflare Access) serves a page with a "Wake Server" button. Pressing it writes a `wake_pending` flag into a KV namespace and optionally posts a confirmation to Telegram.
2. **Poll** -- An always-on ESP32 (LilyGO) polls a second, unauthenticated-by-Access Worker (`wake-api`) every 5 seconds with a Bearer secret. `GET /check` returns the flag; when it is set the ESP32 broadcasts a WoL magic packet on the LAN and clears the flag with `POST /ack`.
3. **Access** -- The PC boots, starts a Cloudflare Tunnel, and exposes Seerr at `seerr.yourdomain.com`.

```
User -> wake-server Worker -> KV <- wake-api Worker <- ESP32 -> WoL -> PC -> Cloudflare Tunnel -> User
```

---

## Setup

### Part 1: ESP32 Firmware (`esp32/`)

1. Install the Arduino IDE (or PlatformIO).
2. Install **ArduinoJson** (v6+) by Benoit Blanchon via Library Manager. The rest (`WiFi`, `WiFiClientSecure`, `WiFiUDP`, `HTTPClient`) ships with the ESP32 core.
3. Copy `esp32/esp32_wol/config.example.h` to `esp32/esp32_wol/config.h` and fill in Wi-Fi, the target MAC, the `wake-api` Worker URL and the shared secret.
4. Flash `esp32/esp32_wol/esp32_wol.ino` to your LilyGO board.

### Part 2: Cloudflare Workers (`cloudflare-worker/`)

Two Workers share one KV namespace (binding `WAKE_QUEUE`, create it once with `wrangler kv namespace create WAKE_QUEUE` and put its id in both `wrangler.toml` files).

1. Install [Wrangler CLI](https://developers.cloudflare.com/workers/wrangler/install-and-update/): `npm i -g wrangler`
2. Authenticate: `wrangler login`
3. `wake-server` (the web page, in `src/`), deployed from `cloudflare-worker/`:
   ```bash
   wrangler secret put TELEGRAM_BOT_TOKEN   # optional: confirmation message on wake
   wrangler secret put TELEGRAM_CHAT_ID
   wrangler deploy
   ```
   Put a Cloudflare Access policy in front of its hostname so only you can press the button.
4. `wake-api` (what the ESP32 polls), deployed from `cloudflare-worker/api/`:
   ```bash
   wrangler secret put ESP32_SECRET          # same value as WORKER_SECRET in config.h
   wrangler deploy
   ```
   This one must **not** be behind Access; it is protected by the Bearer secret only.
5. `seerr-gate` (optional auto-wake, in `seerr-gate/`): a Worker routed onto the Seerr hostname. It passes traffic through untouched while the tunnel is up; when Cloudflare reports the tunnel unreachable (PC asleep) it sets the same KV wake flag and serves a "waking up" page that reloads into Seerr once it answers. Edit the `routes` entry in its `wrangler.toml` to your hostname and zone, then from `cloudflare-worker/seerr-gate/`:
   ```bash
   wrangler secret put TELEGRAM_BOT_TOKEN   # optional note when a visit triggers a wake
   wrangler secret put TELEGRAM_CHAT_ID
   wrangler deploy
   ```

### Part 3: PC Cloudflare Tunnel (`pc/`)

1. Create a tunnel in the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com/).
2. Copy the tunnel token.
3. Copy `pc/.env.example` to `pc/.env` and paste the token.
4. Run: `docker compose up -d`
5. In the Cloudflare dashboard, add a public hostname (e.g. `jellyseerr.yourdomain.com`) pointing to `http://localhost:5055`.

### Part 4: Media Stack (`mediaserver/`)

The *arr stack itself (Sonarr, Radarr, Bazarr, Prowlarr, FlareSolverr, Profilarr, Jellyfin, Seerr, Dozzle).

1. Copy `mediaserver/.env.example` to `mediaserver/.env` and adjust the drive paths.
2. Run from that folder: `docker compose up -d` (project name is pinned to `mediaserver` so the existing `mediaserver_*` volumes are reused).
3. Storage layout: `ROOT_MEDIA_PATH` (F:) is mounted as `/data` and holds the library (`/data/Radarr`, `/data/Sonarr`) and NZBGet's completed folder (`/data/complete`), so imports are instant renames on one filesystem. `OVERFLOW_MOVIES` / `OVERFLOW_SHOWS` (D:) are mounted over `/data/Movies` and `/data/Shows` as second root folders for when F: fills up. Container paths never change when media moves between drives.
4. The download client is a native Windows NZBGet (not a container): intermediate files on `D:\processing`, completed on `F:\complete`. Radarr/Sonarr reach it at `host.docker.internal:6789` with a remote path mapping `F:\complete\` -> `/data/complete/`.
5. `backup-volumes.ps1` tars every `mediaserver_*` volume to `F:\backups\docker-volumes` nightly (Windows scheduled task "ArrStack Volume Backup", 14-day retention).
6. `space-check.ps1` runs every 6 hours (task "ArrStack Space Check"): when F: drops under 150 GB it switches the Seerr default root folders to the D: overflow folders (`/data/Movies`, `/data/Shows`) and sends a Telegram message via `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` from `.env`. Radarr/Sonarr also refuse imports below 50 GB free.
7. `sleep-guard.ps1` runs at logon (task "ArrStack Sleep Guard") and holds a Windows power request while any Jellyfin session is playing and not paused, so the PC does not sleep mid-episode while normal sleep stays enabled. Needs `JELLYFIN_API_KEY` in `.env`.
8. `weekly-digest.ps1` sends a Telegram summary every Sunday (task "ArrStack Weekly Digest"): movies and episodes added, Seerr requests per user, free space, Tdarr savings, backup and watchdog activity. Seerr also notifies via Telegram on request/approval/availability; Radarr and Sonarr only on health issues.

---

## Configuration Variables

| Variable | Where | Description |
|---|---|---|
| `WIFI_SSID` | `esp32/esp32_wol/config.h` | Your Wi-Fi network name |
| `WIFI_PASS` | `esp32/esp32_wol/config.h` | Your Wi-Fi password |
| `TARGET_MAC` | `esp32/esp32_wol/config.h` | MAC address of the PC to wake (AA:BB:CC:DD:EE:FF) |
| `WORKER_URL` | `esp32/esp32_wol/config.h` | URL of the `wake-api` Worker (e.g. `https://wake-api.yourname.workers.dev`) |
| `WORKER_SECRET` | `esp32/esp32_wol/config.h` | Shared secret sent as a Bearer token to `wake-api` |
| `ESP32_SECRET` | `wake-api` Worker secret | Same value as `WORKER_SECRET` |
| `TELEGRAM_BOT_TOKEN` | `wake-server` Worker secret (optional) | Telegram Bot token from @BotFather, for the "wake requested" confirmation |
| `TELEGRAM_CHAT_ID` | `wake-server` Worker secret (optional) | Your Telegram user ID (get from @userinfobot) |
| `TUNNEL_TOKEN` | `pc/.env` | Cloudflare Tunnel token |
| `ROOT_MEDIA_PATH`, `OVERFLOW_MOVIES`, `OVERFLOW_SHOWS` | `mediaserver/.env` | Drive layout for the containers (see Part 4) |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | `mediaserver/.env` | Same bot, used by the space watchdog and weekly digest |
| `JELLYFIN_API_KEY` | `mediaserver/.env` | Jellyfin API key for the sleep guard |
