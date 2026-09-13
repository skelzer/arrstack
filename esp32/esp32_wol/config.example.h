// config.h -- Copy this file to config.h and fill in your values.
// config.h is git-ignored so your secrets stay local.

#ifndef CONFIG_H
#define CONFIG_H

// Wi-Fi credentials
#define WIFI_SSID     "[INSERT_SSID]"
#define WIFI_PASS     "[INSERT_PASS]"

// Machines that can be woken. Each `id` MUST match a target id used by the
// web UI worker (cloudflare-worker/src/index.js -> TARGETS[].id).
//   mac : AA:BB:CC:DD:EE:FF  (used for the broadcast magic packet)
//   ip  : optional unicast IP, "" to skip. Set this when your Wi-Fi AP drops
//         broadcast frames — give the PC a DHCP reservation so the IP is stable.
struct WakeTarget {
  const char* id;
  const char* mac;
  const char* ip;
};

const WakeTarget TARGETS[] = {
  { "server", "[INSERT_SERVER_MAC]", "[INSERT_SERVER_IP]" },  // media server (Ethernet); ip is optional, "" to skip
};

const size_t NUM_TARGETS = sizeof(TARGETS) / sizeof(TARGETS[0]);

// Cloudflare Worker API endpoint (e.g. "https://wake-api.yourname.workers.dev")
#define WORKER_URL    "[INSERT_WORKER_API_URL]"

// Shared secret for ESP32 <-> Worker authentication
#define WORKER_SECRET "[INSERT_WORKER_SECRET]"

#endif
