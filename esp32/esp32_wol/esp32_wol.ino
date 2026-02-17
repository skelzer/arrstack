/*
 * ESP32 Wake-on-LAN Controller
 *
 * Polls a Telegram Bot for /wake and /status commands.
 * On /wake, broadcasts a WoL magic packet to wake the target PC.
 *
 * Board: LilyGO (ESP32-based)
 * Libraries required:
 *   - UniversalTelegramBot (Brian Lough)
 *   - ArduinoJson v6+
 */

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <WiFiUDP.h>
#include <UniversalTelegramBot.h>
#include <ArduinoJson.h>
#include "config.h"

// ── Timing ──────────────────────────────────────────────────────────
const unsigned long BOT_POLL_INTERVAL = 1000;  // 1 second
unsigned long lastPollTime = 0;

// ── Networking objects ──────────────────────────────────────────────
WiFiClientSecure secured;
UniversalTelegramBot bot(BOT_TOKEN, secured);
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

// ── Handle incoming Telegram messages ───────────────────────────────
void handleMessages(int numMessages) {
  for (int i = 0; i < numMessages; i++) {
    String senderId = bot.messages[i].chat_id;
    String text     = bot.messages[i].text;

    // Security: only respond to the configured owner
    if (senderId != CHAT_ID) {
      bot.sendMessage(senderId, "Unauthorized.", "");
      Serial.println("[TELEGRAM] Rejected message from: " + senderId);
      continue;
    }

    Serial.println("[TELEGRAM] Command: " + text);

    if (text == "/wake") {
      uint8_t mac[6];
      if (parseMac(TARGET_MAC, mac)) {
        sendWolPacket(mac);
        bot.sendMessage(CHAT_ID, "Magic Packet Sent!", "");
        Serial.println("[WOL] Magic packet sent to " + String(TARGET_MAC));
      } else {
        bot.sendMessage(CHAT_ID, "Error: invalid MAC address in config.", "");
        Serial.println("[WOL] ERROR: could not parse MAC");
      }
    }
    else if (text == "/status") {
      unsigned long uptimeSec = millis() / 1000;
      String msg = "ESP32 Online\n";
      msg += "Uptime: " + String(uptimeSec / 3600) + "h "
           + String((uptimeSec % 3600) / 60) + "m "
           + String(uptimeSec % 60) + "s\n";
      msg += "RSSI: " + String(WiFi.RSSI()) + " dBm\n";
      msg += "IP: " + WiFi.localIP().toString();
      bot.sendMessage(CHAT_ID, msg, "");
    }
    else if (text == "/start") {
      String welcome = "Wake-on-LAN Bot\n\n";
      welcome += "/wake  - Send magic packet to wake the PC\n";
      welcome += "/status - Show ESP32 uptime and connection info";
      bot.sendMessage(CHAT_ID, welcome, "");
    }
    else {
      bot.sendMessage(CHAT_ID, "Unknown command. Try /wake or /status", "");
    }
  }
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

  // Use built-in root CA store for HTTPS to Telegram
  secured.setCACert(TELEGRAM_CERTIFICATE_ROOT);

  Serial.println("[BOT] Ready. Polling Telegram...");
}

// ── Main loop ───────────────────────────────────────────────────────
void loop() {
  // Reconnect Wi-Fi if dropped
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[WIFI] Connection lost. Reconnecting...");
    connectWiFi();
  }

  // Poll Telegram at the configured interval
  unsigned long now = millis();
  if (now - lastPollTime >= BOT_POLL_INTERVAL) {
    lastPollTime = now;
    int numMessages = bot.getUpdates(bot.last_message_received + 1);
    while (numMessages) {
      handleMessages(numMessages);
      numMessages = bot.getUpdates(bot.last_message_received + 1);
    }
  }
}
