// config.h -- Copy this file to config.h and fill in your values.
// config.h is git-ignored so your secrets stay local.

#ifndef CONFIG_H
#define CONFIG_H

// Wi-Fi credentials
#define WIFI_SSID     "[INSERT_SSID]"
#define WIFI_PASS     "[INSERT_PASS]"

// Machines that can be woken. Each `id` MUST match a target id used by the
// web UI worker (cloudflare-worker/src/index.js -> TARGETS[].id).
// MAC format: AA:BB:CC:DD:EE:FF
struct WakeTarget {
  const char* id;
  const char* mac;
};

const WakeTarget TARGETS[] = {
  { "server",  "[INSERT_SERVER_MAC]"  },  // media server (Ethernet)
  { "desktop", "[INSERT_DESKTOP_MAC]" },  // this PC (Ethernet, e.g. 74:56:3C:4E:C8:A8)
};

const size_t NUM_TARGETS = sizeof(TARGETS) / sizeof(TARGETS[0]);

// Cloudflare Worker API endpoint (e.g. "https://wake-api.yourname.workers.dev")
#define WORKER_URL    "[INSERT_WORKER_API_URL]"

// Shared secret for ESP32 <-> Worker authentication
#define WORKER_SECRET "[INSERT_WORKER_SECRET]"

#endif
