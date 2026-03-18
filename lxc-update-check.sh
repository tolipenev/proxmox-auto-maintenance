#!/bin/bash

NTFY_SERVER="https://ntfy.sh"
NTFY_TOPIC="YOUR_TOPIC"

HOST=$(hostname)
DATE=$(date "+%Y-%m-%d %H:%M")

REPORT="## Proxmox Update Status
**Host:** $HOST
**Time:** $DATE

"

for CTID in $(pct list | awk 'NR>1 {print $1}')
do
    NAME=$(pct config "$CTID" | awk '/hostname/ {print $2}')
    STATUS=$(pct status "$CTID" | awk '{print $2}')

    if [[ "$STATUS" != "running" ]]; then
        REPORT+="- $CTID ($NAME) OFFLINE\n"
        continue
    fi

    timeout 300 pct exec "$CTID" -- apt-get update -qq

    COUNT=$(pct exec "$CTID" -- bash -c "apt list --upgradable 2>/dev/null | tail -n +2 | wc -l")

    REPORT+="- $CTID ($NAME) → $COUNT updates\n"
done

curl -s \
  -H "Markdown: yes" \
  -H "Title: Proxmox Update Check" \
  -d "$REPORT" \
  "$NTFY_SERVER/$NTFY_TOPIC" > /dev/null