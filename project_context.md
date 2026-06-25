# Project: Remote Wake-on-LAN & *arr Stack Access (No Port Forwarding)

## 1. Project Overview
The goal is to create a remote management system for a home media server (*arr stack) running behind a restrictive ISP router ("Salt Box") and an Asus bridge. We need to remotely wake the PC from a sleep state and then securely access services (Jellyseerr/Plex) via a custom domain.

## 2. Hardware Stack
* **Controller Board:** LilyGO (ESP32-based). Always ON.
* **Target PC:** Media Server (*arr stack). Supports Wake-on-LAN (WoL). Connected via Ethernet.
* **Network:**
    * ISP Router (Salt Box) -> Locked down, no port forwarding access.
    * Asus Router (Bridge Mode) -> Transparent bridge.
    * **Constraint:** No inbound connections allowed. All control must use outbound polling or tunnels.

## 3. Architecture Design

### Part A: The "Wake" Mechanism (Web -> Telegram -> ESP32 -> PC)
Since we cannot host a web server directly on the ESP32 (due to router restrictions), we will use **Telegram** as a message queue middleware.
1.  **User Action:** User visits a specific URL (e.g., `wake.mydomain.com` or a Cloudflare Worker).
2.  **Trigger:** This URL triggers a script that sends a message to a private Telegram Bot.
3.  **Poller:** The LilyGO (ESP32) is constantly polling the Telegram Bot API (Long Polling).
4.  **Action:** When the ESP32 sees the specific "Wake" command, it broadcasts a generic WoL Magic Packet to the LAN.

### Part B: The "Access" Mechanism (User -> Cloudflare Tunnel -> PC)
Once the PC is awake:
1.  The PC runs **Cloudflared** (Cloudflare Tunnel daemon).
2.  This creates an outbound tunnel to Cloudflare, bypassing the router firewall.
3.  User accesses `jellyseerr.mydomain.com`, which routes through the tunnel to the PC.

---

## 4. Implementation Tasks for AI Assistant

### Task 1: Firmware Development (ESP32)
**Goal:** Create a C++/Arduino sketch for the LilyGO.
* **Libraries:** `WiFi.h`, `WiFiClientSecure.h`, `UniversalTelegramBot.h`, `ArduinoJson`, `WakeOnLan` (or raw UDP implementation).
* **Functionality:**
    1.  Connect to Wi-Fi.
    2.  Poll Telegram Bot API every 1-2 seconds.
    3.  Listen for command `/wake`.
    4.  Verify `chat_id` matches the owner (security).
    5.  Send Magic Packet to Target PC MAC Address.
    6.  Reply to Telegram: "Magic Packet Sent".

### Task 2: The "Web Wake" Button (Cloudflare Worker)
**Goal:** Create a script to allow waking the PC via a browser, so I don't *have* to use the Telegram app.
* **Platform:** Cloudflare Worker (JavaScript/ES Modules).
* **Functionality:**
    1.  Serve a simple HTML page with a big "Wake Server" button.
    2.  On click, send a `POST` request to `https://api.telegram.org/bot<TOKEN>/sendMessage`.
    3.  Payload: `{"chat_id": "<MY_ID>", "text": "/wake"}`.
    * *Note: This effectively allows the web page to "talk" to the ESP32 via Telegram.*

### Task 3: PC Configuration (Cloudflared)
**Goal:** Expose Jellyseerr securely without port forwarding.
* **Action:** Generate a `docker-compose.yml` snippet for the PC.
* **Service:** `cloudflared` (tunnel).
* **Config:** Map internal port `5055` (Jellyseerr) to the tunnel.

---

## 5. Configuration Variables (To Be Filled)
* **WiFi SSID:** `[INSERT_SSID]`
* **WiFi Password:** `[INSERT_PASS]`
* **Telegram Bot Token:** `[INSERT_BOT_TOKEN]`
* **Telegram User ID:** `[INSERT_USER_ID]`
* **Wake targets:** `TARGETS[]` in `esp32/config.h` — one `{ id, mac }` per machine (e.g. `server`, `desktop`). Each `id` must match a button target in `cloudflare-worker/src/index.js`.
  * Desktop (this PC) Ethernet MAC: `74:56:3C:4E:C8:A8`