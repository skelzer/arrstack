/*
 * ESP32 Wake-on-LAN Controller
 *
 * Polls a Cloudflare Worker for wake commands.
 * On wake, broadcasts a WoL magic packet to wake the target PC.
 *
 * Board: LilyGO (ESP32-based)
 * Libraries required:
 *   - ArduinoJson v6+
 */

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <WiFiUDP.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include "config.h"

// ── Timing ──────────────────────────────────────────────────────────
const unsigned long WORKER_POLL_INTERVAL = 5000;  // 5 seconds
unsigned long lastWorkerPollTime = 0;

// ── Networking objects ──────────────────────────────────────────────
WiFiClientSecure securedWorker;
WiFiUDP udp;

// ── WoL constants ───────────────────────────────────────────────────
const int WOL_PORT = 9;
const IPAddress BROADCAST_IP(255, 255, 255, 255);

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
void sendWolPacket(const uint8_t* mac) {
  uint8_t packet[102];

  // 6 bytes of 0xFF header
  memset(packet, 0xFF, 6);

  // 16 repetitions of target MAC
  for (int i = 0; i < 16; i++) {
    memcpy(&packet[6 + i * 6], mac, 6);
  }

  udp.beginPacket(BROADCAST_IP, WOL_PORT);
  udp.write(packet, sizeof(packet));
  udp.endPacket();
}

// ── Look up a target id's MAC and send a WoL packet to it ───────────
bool doWake(const char* targetId) {
  for (size_t i = 0; i < NUM_TARGETS; i++) {
    if (strcmp(targetId, TARGETS[i].id) == 0) {
      uint8_t mac[6];
      if (parseMac(TARGETS[i].mac, mac)) {
        sendWolPacket(mac);
        Serial.println("[WOL] Magic packet sent to " + String(TARGETS[i].id) +
                       " (" + String(TARGETS[i].mac) + ")");
        return true;
      }
      Serial.println("[WOL] ERROR: could not parse MAC for " + String(targetId));
      return false;
    }
  }
  Serial.println("[WOL] WARN: unknown target id '" + String(targetId) + "'");
  return false;
}

// ── Poll Cloudflare Worker for web-triggered wakes ──────────────────
void pollWorker() {
  HTTPClient http;
  String checkUrl = String(WORKER_URL) + "/check";

  http.begin(securedWorker, checkUrl);
  http.addHeader("Authorization", String("Bearer ") + WORKER_SECRET);

  int httpCode = http.GET();
  if (httpCode == 200) {
    String payload = http.getString();
    StaticJsonDocument<256> doc;
    DeserializationError err = deserializeJson(doc, payload);

    if (!err) {
      JsonArray targets = doc["targets"].as<JsonArray>();
      for (JsonVariant t : targets) {
        const char* targetId = t.as<const char*>();
        if (!targetId) continue;
        Serial.println("[WORKER] Wake request for '" + String(targetId) + "'");

        // Ack regardless of MAC-parse outcome so a bad id can't wedge the queue.
        doWake(targetId);
        ackWorker(targetId);
      }
    } else {
      Serial.println("[WORKER] JSON parse error: " + String(err.c_str()));
    }
  } else if (httpCode > 0) {
    Serial.println("[WORKER] Check returned HTTP " + String(httpCode));
  } else {
    Serial.println("[WORKER] Check failed: " + http.errorToString(httpCode));
  }

  http.end();
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

// ── Wi-Fi connection with retry ─────────────────────────────────────
void connectWiFi() {
  Serial.print("[WIFI] Connecting to ");
  Serial.println(WIFI_SSID);

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);

  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
    attempts++;
    if (attempts > 40) {  // 20 seconds
      Serial.println("\n[WIFI] Failed to connect. Restarting...");
      ESP.restart();
    }
  }

  Serial.println();
  Serial.println("[WIFI] Connected!");
  Serial.print("[WIFI] IP: ");
  Serial.println(WiFi.localIP());
}

// ── Setup ───────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  delay(100);
  Serial.println("\n=== ESP32 WoL Controller ===");

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
}
