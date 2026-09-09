# Remote Wake-on-LAN & *arr Stack Access

Remotely wake a media server PC and securely access services (Jellyseerr/Plex) without port forwarding.

## How It Works

1. **Wake** -- A Cloudflare Worker serves a web page with a "Wake Server" button. Pressing it sends a `/wake` command to a Telegram bot.
2. **Poll** -- An always-on ESP32 (LilyGO) polls the Telegram Bot API. When it sees `/wake`, it broadcasts a WoL magic packet on the LAN.
3. **Access** -- The PC boots, starts a Cloudflare Tunnel, and exposes Jellyseerr at `jellyseerr.yourdomain.com`.

```
User -> Cloudflare Worker -> Telegram Bot API <- ESP32 -> WoL -> PC -> Cloudflare Tunnel -> User
```

---

## Setup

### Part 1: ESP32 Firmware (`esp32/`)

1. Install the Arduino IDE (or PlatformIO).
2. Install the following libraries via Library Manager:
   - **UniversalTelegramBot** by Brian Lough
   - **ArduinoJson** (v6+) by Benoit Blanchon
3. Copy `esp32/config.example.h` to `esp32/config.h` and fill in your values.
4. Flash `esp32/esp32_wol.ino` to your LilyGO board.

### Part 2: Cloudflare Worker (`cloudflare-worker/`)

1. Install [Wrangler CLI](https://developers.cloudflare.com/workers/wrangler/install-and-update/): `npm i -g wrangler`
2. Authenticate: `wrangler login`
3. Set secrets:
   ```bash
   wrangler secret put TELEGRAM_BOT_TOKEN
   wrangler secret put TELEGRAM_CHAT_ID
   ```
4. Deploy: `wrangler deploy`

### Part 3: PC Cloudflare Tunnel (`pc/`)

1. Create a tunnel in the [Cloudflare Zero Trust dashboard](https://one.dash.cloudflare.com/).
2. Copy the tunnel token.
3. Copy `pc/.env.example` to `pc/.env` and paste the token.
4. Run: `docker compose up -d`
5. In the Cloudflare dashboard, add a public hostname (e.g. `jellyseerr.yourdomain.com`) pointing to `http://localhost:5055`.

### Part 4: Media Stack (`mediaserver/`)

The *arr stack itself (Sonarr, Radarr, Lidarr, Bazarr, Prowlarr, FlareSolverr, Profilarr, Jellyfin, Seerr, Dozzle).

1. Copy `mediaserver/.env.example` to `mediaserver/.env` and adjust the drive paths.
2. Run from that folder: `docker compose up -d` (project name is pinned to `mediaserver` so the existing `mediaserver_*` volumes are reused).
3. Storage layout: `ROOT_MEDIA_PATH` (D:) is mounted as `/data` for downloads and overflow; `LIBRARY_MOVIES` / `LIBRARY_SHOWS` (F:) are mounted over `/data/Radarr` and `/data/Sonarr`, so the container paths never change when media moves between drives.
4. The download client is a native Windows NZBGet (not a container). Radarr/Sonarr reach it at `host.docker.internal:6789` with a remote path mapping `D:\complete\` -> `/data/complete/`.
5. `backup-volumes.ps1` tars every `mediaserver_*` volume to `F:ackups\docker-volumes` nightly (Windows scheduled task "ArrStack Volume Backup", 14-day retention).

---

## Configuration Variables

| Variable | Where | Description |
|---|---|---|
| `WIFI_SSID` | `esp32/config.h` | Your Wi-Fi network name |
| `WIFI_PASS` | `esp32/config.h` | Your Wi-Fi password |
| `BOT_TOKEN` | `esp32/config.h` | Telegram Bot token from @BotFather |
| `CHAT_ID` | `esp32/config.h` | Your Telegram user ID (get from @userinfobot) |
| `TARGET_MAC` | `esp32/config.h` | MAC address of the PC to wake (AA:BB:CC:DD:EE:FF) |
| `TELEGRAM_BOT_TOKEN` | Cloudflare Worker secret | Same Telegram Bot token |
| `TELEGRAM_CHAT_ID` | Cloudflare Worker secret | Same Telegram user ID |
| `TUNNEL_TOKEN` | `pc/.env` | Cloudflare Tunnel token |
