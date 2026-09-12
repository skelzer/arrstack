#!/bin/sh
# wake-poller.sh -- Asuswrt-Merlin replacement for the ESP32 wake duty.
# Polls the wake-api Worker; when a wake is pending, sends a WoL magic packet on the LAN
# and acknowledges it. Runs forever; started at boot from /jffs/scripts/services-start.
#
# Install (after flashing Merlin, enabling JFFS custom scripts and SSH):
#   scp router/wake-poller.sh  admin@192.168.1.50:/jffs/scripts/wake-poller.sh
#   scp router/wake-poller.conf admin@192.168.1.50:/jffs/configs/wake-poller.conf   # from wake-poller.conf.example
#   ssh admin@192.168.1.50 'chmod +x /jffs/scripts/wake-poller.sh; \
#     grep -q wake-poller /jffs/scripts/services-start 2>/dev/null || \
#     { [ -f /jffs/scripts/services-start ] || printf "#!/bin/sh\n" > /jffs/scripts/services-start; \
#       echo "/jffs/scripts/wake-poller.sh &" >> /jffs/scripts/services-start; chmod +x /jffs/scripts/services-start; }; \
#     /jffs/scripts/wake-poller.sh &'
#
# Logs go to the router syslog (System Log in the UI): logger -t wake-poller

CONF=/jffs/configs/wake-poller.conf
[ -f "$CONF" ] || { logger -t wake-poller "missing $CONF"; exit 1; }
. "$CONF"   # WORKER_URL, WORKER_SECRET, TARGET_MAC, optional POLL_SECONDS, LAN_IF

POLL_SECONDS=${POLL_SECONDS:-5}
LAN_IF=${LAN_IF:-br0}
logger -t wake-poller "started: url=$WORKER_URL mac=$TARGET_MAC every ${POLL_SECONDS}s"

while true; do
    resp=$(curl -s -m 8 -H "Authorization: Bearer $WORKER_SECRET" "$WORKER_URL/check" 2>/dev/null)
    case "$resp" in
        *'"wake":true'*)
            # busybox ether-wake sends the magic packet as a broadcast on the given interface
            ether-wake -i "$LAN_IF" -b "$TARGET_MAC" 2>/dev/null || ether-wake -i "$LAN_IF" "$TARGET_MAC"
            logger -t wake-poller "wake requested -> magic packet sent to $TARGET_MAC"
            curl -s -m 8 -X POST -H "Authorization: Bearer $WORKER_SECRET" -H "Content-Type: application/json" -d '{}' "$WORKER_URL/ack" >/dev/null 2>&1 \
                && logger -t wake-poller "acknowledged" || logger -t wake-poller "ack failed"
            ;;
    esac
    sleep "$POLL_SECONDS"
done
