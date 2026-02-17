// config.h -- Copy this file to config.h and fill in your values.
// config.h is git-ignored so your secrets stay local.

#ifndef CONFIG_H
#define CONFIG_H

// Wi-Fi credentials
#define WIFI_SSID     "[INSERT_SSID]"
#define WIFI_PASS     "[INSERT_PASS]"

// MAC address of the PC to wake (format: AA:BB:CC:DD:EE:FF)
#define TARGET_MAC    "[INSERT_MAC_ADDRESS]"

// Cloudflare Worker API endpoint (e.g. "https://wake-api.yourname.workers.dev")
#define WORKER_URL    "[INSERT_WORKER_API_URL]"

// Shared secret for ESP32 <-> Worker authentication
#define WORKER_SECRET "[INSERT_WORKER_SECRET]"

#endif
