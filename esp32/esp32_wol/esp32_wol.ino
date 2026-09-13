/*
 * ESP32 Wake-on-LAN controller + status display
 *
 * Polls a Cloudflare Worker (wake-api) for wake commands and for the media
 * server's live status (free space on the library drives, what Jellyfin is
 * playing). Sends the WoL magic packet on request and shows the status on the
 * screen.
 *
 * Board: LilyGO TTGO T-Display (ESP32, ST7789 1.14" 135x240)
 * Libraries required:
 *   - ArduinoJson v6+
 *   - TFT_eSPI (in its User_Setup_Select.h, select Setup25_TTGO_T_Display.h)
 *   - TJpg_Decoder (draws the now-playing poster)
 */

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <WiFiUDP.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <TFT_eSPI.h>
#include <TJpg_Decoder.h>
#include "config.h"

// ── Timing ──────────────────────────────────────────────────────────
const unsigned long WORKER_POLL_INTERVAL = 5000;    // 5 seconds
const long          STATUS_FRESH_S       = 300;     // status older than this = server asleep (PC pushes every 2 min)
const unsigned long WAKING_TIMEOUT_MS    = 180000;  // show WAKING for at most 3 min after a wake
unsigned long lastWorkerPollTime = 0;

// ── Networking / display objects ────────────────────────────────────
WiFiClientSecure securedWorker;
WiFiUDP udp;
TFT_eSPI tft = TFT_eSPI();

// ── What the screen shows ───────────────────────────────────────────
struct ServerStatus {
  bool   pollOk   = false;  // last /check succeeded
  bool   online   = false;  // PC pushed a status recently
  bool   haveData = false;  // at least one /check parsed
  int    freeF    = -1;     // GB, -1 = unknown
  int    freeD    = -1;
  String playTitle;         // empty = idle
  String playUser;
};
ServerStatus status;
unsigned long wakingSince = 0;   // millis() of the last magic packet, 0 = none
bool screenDirty = true;

// ── Now-playing poster (60x90 baseline JPEG served by the Worker) ───
const int    POSTER_X = 174, POSTER_Y = 6, POSTER_W = 60, POSTER_H = 90;
const size_t POSTER_MAX_BYTES = 20 * 1024;
uint8_t* posterBuf = nullptr;   // JPEG bytes of the poster currently shown
size_t   posterLen = 0;
String   posterId;              // Jellyfin item id the buffer belongs to ("" = none)

void   applyStatus(JsonVariant s);
void   ackWorker(const char* targetId);
bool   fetchPoster();
void   clearPoster();
void   drawScreen();
void   drawDrive(const char* label, int freeGb, int y);
String fitToWidth(String s, int maxPx, int font);

// ── WoL constants ───────────────────────────────────────────────────
const int WOL_PORT = 9;
const IPAddress LIMITED_BROADCAST(255, 255, 255, 255);

// Subnet-directed broadcast for the ESP32's own network (e.g. 192.168.1.255).
// Wi-Fi APs commonly drop 255.255.255.255 from wireless clients but forward
// the subnet-directed broadcast, so we send to both for reliability.
IPAddress directedBroadcast() {
  IPAddress ip = WiFi.localIP();
  IPAddress mask = WiFi.subnetMask();
  IPAddress bc;
  for (int i = 0; i < 4; i++) {
    bc[i] = ip[i] | (~mask[i] & 0xFF);
  }
  return bc;
}

// ── Parse MAC string "AA:BB:CC:DD:EE:FF" into 6-byte array ─────────
bool parseMac(const char* macStr, uint8_t* out) {
  int values[6];
  int matched = sscanf(macStr, "%x:%x:%x:%x:%x:%x",
                       &values[0], &values[1], &values[2],
                       &values[3], &values[4], &values[5]);
  if (matched != 6) return false;
  for (int i = 0; i < 6; i++) {
    out[i] = (uint8_t)values[i];
  }
  return true;
}

// ── Build and send WoL magic packet ─────────────────────────────────
// Magic packet: 6 bytes of 0xFF followed by the MAC repeated 16 times
// (102 bytes total).

// Send the magic packet to one destination IP.
void sendPacketTo(const IPAddress& dest, const uint8_t* packet, size_t len) {
  udp.beginPacket(dest, WOL_PORT);
  udp.write(packet, len);
  udp.endPacket();
}

void sendWolPacket(const uint8_t* mac, const char* targetIp) {
  uint8_t packet[102];

  // 6 bytes of 0xFF header
  memset(packet, 0xFF, 6);

  // 16 repetitions of target MAC
  for (int i = 0; i < 16; i++) {
    memcpy(&packet[6 + i * 6], mac, 6);
  }

  // 1) Subnet-directed broadcast (most reliable over Wi-Fi).
  IPAddress directed = directedBroadcast();
  sendPacketTo(directed, packet, sizeof(packet));

  // 2) Limited broadcast as a fallback.
  sendPacketTo(LIMITED_BROADCAST, packet, sizeof(packet));

  // 3) Unicast to the target IP if configured. Works even when the AP drops
  //    broadcast frames from wireless clients; relies on the NIC answering
  //    ARP while asleep (ARP-offload, which most NICs do).
  String extra = "";
  if (targetIp && targetIp[0] != '\0') {
    IPAddress ip;
    if (ip.fromString(targetIp)) {
      sendPacketTo(ip, packet, sizeof(packet));
      extra = " + unicast " + ip.toString();
    } else {
      Serial.println("[WOL] WARN: bad target IP '" + String(targetIp) + "'");
    }
  }

  Serial.println("[WOL] Sent to " + directed.toString() +
                 ", 255.255.255.255" + extra + " (port " + String(WOL_PORT) + ")");
}

// ── Look up a target id's MAC and send a WoL packet to it ───────────
bool doWake(const char* targetId) {
  for (size_t i = 0; i < NUM_TARGETS; i++) {
    if (strcmp(targetId, TARGETS[i].id) == 0) {
      uint8_t mac[6];
      if (parseMac(TARGETS[i].mac, mac)) {
        sendWolPacket(mac, TARGETS[i].ip);
        Serial.println("[WOL] Magic packet sent to " + String(TARGETS[i].id) +
                       " (" + String(TARGETS[i].mac) + ")");
        wakingSince = millis();
        screenDirty = true;
        return true;
      }
      Serial.println("[WOL] ERROR: could not parse MAC for " + String(targetId));
      return false;
    }
  }
  Serial.println("[WOL] WARN: unknown target id '" + String(targetId) + "'");
  return false;
}

// ── Poll Cloudflare Worker: pending wakes + server status ───────────
void pollWorker() {
  HTTPClient http;
  String checkUrl = String(WORKER_URL) + "/check";

  http.begin(securedWorker, checkUrl);
  http.addHeader("Authorization", String("Bearer ") + WORKER_SECRET);

  bool ok = false;
  int httpCode = http.GET();
  if (httpCode == 200) {
    String payload = http.getString();
    StaticJsonDocument<1536> doc;
    DeserializationError err = deserializeJson(doc, payload);

    if (!err) {
      ok = true;
      JsonArray targets = doc["targets"].as<JsonArray>();
      for (JsonVariant t : targets) {
        const char* targetId = t.as<const char*>();
        if (!targetId) continue;
        Serial.println("[WORKER] Wake request for '" + String(targetId) + "'");

        // Ack regardless of MAC-parse outcome so a bad id can't wedge the queue.
        doWake(targetId);
        ackWorker(targetId);
      }
      applyStatus(doc["status"]);
    } else {
      Serial.println("[WORKER] JSON parse error: " + String(err.c_str()));
    }
  } else if (httpCode > 0) {
    Serial.println("[WORKER] Check returned HTTP " + String(httpCode));
  } else {
    Serial.println("[WORKER] Check failed: " + http.errorToString(httpCode));
  }

  http.end();

  if (status.pollOk != ok) {
    status.pollOk = ok;
    screenDirty = true;
  }
}

// ── Copy the Worker's `status` object into what the screen shows ────
// null = the PC has not pushed anything recently (asleep or script not running).
void applyStatus(JsonVariant s) {
  bool   online = false;
  int    freeF = -1, freeD = -1;
  String title, user;

  if (!s.isNull()) {
    long age = s["age_s"] | 999999L;
    online = age >= 0 && age < STATUS_FRESH_S;
    freeF  = s["free"]["F"] | -1;
    freeD  = s["free"]["D"] | -1;

    JsonArray playing = s["playing"].as<JsonArray>();
    if (playing.size() > 0) {
      title = playing[0]["title"] | "";
      user  = playing[0]["user"]  | "";
      if (playing.size() > 1) user += " +" + String(playing.size() - 1);
    }
  }

  if (!status.haveData || online != status.online || freeF != status.freeF ||
      freeD != status.freeD || title != status.playTitle || user != status.playUser) {
    status.haveData  = true;
    status.online    = online;
    status.freeF     = freeF;
    status.freeD     = freeD;
    status.playTitle = title;
    status.playUser  = user;
    screenDirty = true;
  }

  if (online) wakingSince = 0;   // PC answered: no longer "waking"

  // Poster: refetch when the item changed, drop it when nothing is playing.
  // A failed fetch leaves posterId empty so the next poll retries.
  String newPosterId = String(s["poster_id"] | "");
  if (newPosterId != posterId) {
    if (newPosterId.length() > 0 && fetchPoster()) {
      posterId = newPosterId;
    } else {
      clearPoster();
    }
    screenDirty = true;
  }
}

// ── Poster: fetch from the Worker, decode with TJpg_Decoder ─────────
bool tftOutput(int16_t x, int16_t y, uint16_t w, uint16_t h, uint16_t* bitmap) {
  if (y >= tft.height()) return 0;
  tft.pushImage(x, y, w, h, bitmap);
  return 1;
}

void clearPoster() {
  free(posterBuf);
  posterBuf = nullptr;
  posterLen = 0;
  posterId  = "";
}

// Download /poster into posterBuf. On failure the previous poster is kept.
bool fetchPoster() {
  HTTPClient http;
  http.setReuse(false);   // server closes after the body, so the read loop ends cleanly
  http.begin(securedWorker, String(WORKER_URL) + "/poster");
  http.addHeader("Authorization", String("Bearer ") + WORKER_SECRET);

  int httpCode = http.GET();
  if (httpCode != 200) {
    Serial.println("[POSTER] HTTP " + String(httpCode));
    http.end();
    return false;
  }

  int    len = http.getSize();   // -1 when unknown
  size_t cap = (len > 0 && (size_t)len <= POSTER_MAX_BYTES) ? (size_t)len : POSTER_MAX_BYTES;
  uint8_t* buf = (uint8_t*)malloc(cap);
  if (!buf) {
    Serial.println("[POSTER] out of memory");
    http.end();
    return false;
  }

  WiFiClient* stream = http.getStreamPtr();
  size_t got = 0;
  unsigned long start = millis();
  while (http.connected() && got < cap && millis() - start < 8000) {
    size_t avail = stream->available();
    if (avail == 0) { delay(5); continue; }
    got += stream->readBytes(buf + got, min(avail, cap - got));
    if (len > 0 && got >= (size_t)len) break;
  }
  http.end();

  if (got == 0 || (len > 0 && got < (size_t)len)) {
    Serial.println("[POSTER] incomplete download (" + String(got) + " bytes)");
    free(buf);
    return false;
  }

  free(posterBuf);
  posterBuf = buf;
  posterLen = got;
  Serial.println("[POSTER] got " + String(got) + " bytes");
  return true;
}

// ── Acknowledge a web wake to the Worker ────────────────────────────
void ackWorker(const char* targetId) {
  HTTPClient http;
  String ackUrl = String(WORKER_URL) + "/ack";

  http.begin(securedWorker, ackUrl);
  http.addHeader("Authorization", String("Bearer ") + WORKER_SECRET);
  http.addHeader("Content-Type", "application/json");

  String body = String("{\"target\":\"") + targetId + "\"}";
  int httpCode = http.POST(body);
  if (httpCode == 200) {
    Serial.println("[WORKER] Acknowledged wake for " + String(targetId));
  } else {
    Serial.println("[WORKER] Ack failed for " + String(targetId) +
                   ": HTTP " + String(httpCode));
  }

  http.end();
}

// ── Screen (240x135 landscape) ──────────────────────────────────────
//  MEDIA SERVER                 UP
//  F:  812 GB
//  D:  340 GB
//  > Dune (Miguel)
//  192.168.1.45
void drawScreen() {
  screenDirty = false;
  tft.fillScreen(TFT_BLACK);
  tft.setTextDatum(TL_DATUM);

  // Header: name + state badge
  tft.setTextColor(TFT_LIGHTGREY, TFT_BLACK);
  tft.drawString("MEDIA SERVER", 6, 6, 2);

  bool waking = wakingSince != 0 && (millis() - wakingSince) < WAKING_TIMEOUT_MS && !status.online;
  const char* state;
  uint16_t    color;
  if (!status.pollOk)     { state = "NO LINK"; color = TFT_RED;      }
  else if (status.online) { state = "UP";      color = TFT_GREEN;    }
  else if (waking)        { state = "WAKING";  color = TFT_YELLOW;   }
  else                    { state = "ASLEEP";  color = TFT_DARKGREY; }
  tft.setTextDatum(TR_DATUM);
  tft.setTextColor(color, TFT_BLACK);
  tft.drawString(state, POSTER_X - 6, 6, 2);   // right-aligned, left of the poster
  tft.setTextDatum(TL_DATUM);

  // Now-playing poster on the right, when we have one
  if (posterBuf && posterLen > 0) {
    TJpgDec.drawJpg(POSTER_X, POSTER_Y, posterBuf, posterLen);
  }

  // Free space, one big line per drive
  drawDrive("F:", status.freeF, 32);
  drawDrive("D:", status.freeD, 62);

  // Now playing
  String line;
  if (status.playTitle.length() > 0) {
    line = "> " + status.playTitle;
    if (status.playUser.length() > 0) line += " (" + status.playUser + ")";
    tft.setTextColor(TFT_WHITE, TFT_BLACK);
  } else {
    line = status.online ? "idle" : "";
    tft.setTextColor(TFT_DARKGREY, TFT_BLACK);
  }
  tft.drawString(fitToWidth(line, 228, 2), 6, 98, 2);

  // Footer
  tft.setTextColor(TFT_DARKGREY, TFT_BLACK);
  tft.drawString(WiFi.localIP().toString(), 6, 120, 1);
}

void drawDrive(const char* label, int freeGb, int y) {
  tft.setTextColor(TFT_LIGHTGREY, TFT_BLACK);
  tft.drawString(label, 6, y, 4);

  String   value = freeGb < 0 ? "--" : String(freeGb);
  uint16_t color = freeGb < 0 ? TFT_DARKGREY
                 : (freeGb < 150 ? TFT_ORANGE : TFT_WHITE);   // 150 GB = space-check threshold
  tft.setTextColor(color, TFT_BLACK);
  tft.drawString(value, 44, y, 4);

  tft.setTextColor(TFT_LIGHTGREY, TFT_BLACK);
  tft.drawString("GB", 44 + tft.textWidth(value, 4) + 6, y + 8, 2);
}

// Shorten a string with "..." so it fits in `maxPx` pixels at `font`.
String fitToWidth(String s, int maxPx, int font) {
  if (tft.textWidth(s, font) <= maxPx) return s;
  while (s.length() > 1 && tft.textWidth(s + "...", font) > maxPx) {
    s.remove(s.length() - 1);
  }
  return s + "...";
}

void showMessage(const char* msg) {
  tft.fillScreen(TFT_BLACK);
  tft.setTextDatum(TL_DATUM);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.drawString(msg, 6, 6, 2);
}

// ── Wi-Fi connection with retry ─────────────────────────────────────
void connectWiFi() {
  Serial.print("[WIFI] Connecting to ");
  Serial.println(WIFI_SSID);
  showMessage("connecting wifi...");

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);

  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
    attempts++;
    if (attempts > 40) {  // 20 seconds
      Serial.println("\n[WIFI] Failed to connect. Restarting...");
      showMessage("wifi failed, restarting");
      delay(1000);
      ESP.restart();
    }
  }

  Serial.println();
  Serial.println("[WIFI] Connected!");
  Serial.print("[WIFI] IP: ");
  Serial.println(WiFi.localIP());
  screenDirty = true;
}

// ── Setup ───────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(100);
  Serial.println("\n=== ESP32 WoL Controller ===");

  tft.init();
  tft.setRotation(1);   // landscape, USB port on the right
#ifdef TFT_BL
  pinMode(TFT_BL, OUTPUT);
  digitalWrite(TFT_BL, HIGH);
#endif
  TJpgDec.setJpgScale(1);
  TJpgDec.setSwapBytes(true);   // TFT_eSPI expects big-endian 16-bit pixels
  TJpgDec.setCallback(tftOutput);

  connectWiFi();

  // Skip full cert verification for Worker (still encrypted, auth via Bearer token)
  securedWorker.setInsecure();

  Serial.println("[READY] Polling Cloudflare Worker every 5s...");
}

// ── Main loop ───────────────────────────────────────────────────────
void loop() {
  // Reconnect Wi-Fi if dropped
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[WIFI] Connection lost. Reconnecting...");
    connectWiFi();
  }

  unsigned long now = millis();

  // Poll Cloudflare Worker at 5s interval
  if (now - lastWorkerPollTime >= WORKER_POLL_INTERVAL) {
    lastWorkerPollTime = now;
    pollWorker();
  }

  // Stop showing WAKING once the wake has had its 3 minutes
  if (wakingSince != 0 && now - wakingSince >= WAKING_TIMEOUT_MS) {
    wakingSince = 0;
    screenDirty = true;
  }

  if (screenDirty) drawScreen();
}
