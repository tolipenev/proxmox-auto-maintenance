#!/bin/bash


# LXC Update Check


NTFY_SERVER="https://ntfy.sh"
NTFY_TOPIC="YOUR_TOPIC"
ENABLE_NTFY=true

HOST=$(hostname)
DATE=$(date "+%Y-%m-%d %H:%M")

# Threshold for highlighting
HIGH_UPDATE_THRESHOLD=0

# Colors
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

REPORT="## Proxmox Update Status
**Host:** $HOST
**Time:** $DATE

"

TOTAL_UPDATES=0

for CTID in $(pct list | awk 'NR>1 {print $1}')
do
    START=$(date +%s)

    NAME=$(pct config "$CTID" | awk '/hostname/ {print $2}')
    STATUS=$(pct status "$CTID" | awk '{print $2}')

    echo -e "${CYAN}[$CTID] $NAME${RESET}"

    if [[ "$STATUS" != "running" ]]; then
        echo -e "  ${RED}OFFLINE${RESET}"
        REPORT+="- $CTID ($NAME) OFFLINE"$'\n'
        continue
    fi

    DISTRO=$(pct exec "$CTID" -- sh -c "grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2")

    COUNT=0

    case "$DISTRO" in
        debian|ubuntu)
            timeout 300 pct exec "$CTID" -- apt-get update -qq
            COUNT=$(pct exec "$CTID" -- sh -c "apt list --upgradable 2>/dev/null | tail -n +2 | wc -l")
            ;;

        alpine)
            timeout 300 pct exec "$CTID" -- apk update >/dev/null 2>&1
            COUNT=$(pct exec "$CTID" -- sh -c "apk list -u 2>/dev/null | wc -l")
            ;;

        arch)
            timeout 300 pct exec "$CTID" -- pacman -Sy --noconfirm >/dev/null 2>&1
            COUNT=$(pct exec "$CTID" -- sh -c "pacman -Qu 2>/dev/null | wc -l")
            ;;

        fedora|rhel|centos)
            timeout 300 pct exec "$CTID" -- dnf check-update >/dev/null 2>&1
            COUNT=$(pct exec "$CTID" -- sh -c "dnf check-update 2>/dev/null | grep -E '^[a-zA-Z0-9]' | wc -l")
            ;;

        *)
            echo -e "  ${RED}Unsupported distro: $DISTRO${RESET}"
            REPORT+="- $CTID ($NAME) unsupported ($DISTRO)"$'\n'
            continue
            ;;
    esac

    END=$(date +%s)
    DURATION=$((END - START))

    TOTAL_UPDATES=$((TOTAL_UPDATES + COUNT))

    # Highlight logic
    if [[ "$COUNT" -ge "$HIGH_UPDATE_THRESHOLD" ]]; then
        echo -e "  ${YELLOW}$COUNT updates (${DURATION}s) [HIGH]${RESET}"
        REPORT+="- $CTID ($NAME) → **$COUNT updates** (${DURATION}s) ⚠"$'\n'
    else
        echo -e "  ${GREEN}$COUNT updates (${DURATION}s)${RESET}"
        REPORT+="- $CTID ($NAME) → $COUNT updates (${DURATION}s)"$'\n'
    fi

done

REPORT+=$'\n'"**Total pending updates:** $TOTAL_UPDATES"$'\n'

# SEND NOTIFICATION

if [[ "$ENABLE_NTFY" == true ]]; then
    curl -s \
      -H "Markdown: yes" \
      -H "Title: Proxmox Update Check" \
      -d "$REPORT" \
      "$NTFY_SERVER/$NTFY_TOPIC" > /dev/null

    echo -e "\n${GREEN}ntfy notification sent${RESET}"
else
    echo -e "\n${YELLOW}ntfy disabled (ENABLE_NTFY=false)${RESET}"
fi
