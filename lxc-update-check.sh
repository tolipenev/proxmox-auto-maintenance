#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

LOCKFILE="/var/run/lxc-update-check.lock"
exec 200>$LOCKFILE
flock -n 200 || exit 0

# NTFY CONFIG
NTFY_SERVER="https://ntfy.techhome.app"
NTFY_TOPIC="LXC_Update_P1"
ENABLE_NTFY=true

# SETTINGS
HIGH_UPDATE_THRESHOLD=8
TOTAL_THRESHOLD=15
ONLY_NOTIFY_IF_IMPORTANT=true

HOST=$(hostname)
DATE=$(date "+%Y-%m-%d %H:%M")

TOTAL_UPDATES=0
IMPORTANT=false

GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

echo "=== LXC Update Check ==="

REPORT="Host: $HOST"$'\n'
REPORT+="Time: $DATE"$'\n\n'

# ---------------- LXC ----------------

for CTID in $(pct list | awk 'NR>1 {print $1}'); do
    START=$(date +%s)

    NAME=$(pct config "$CTID" | awk '/hostname/ {print $2}')
    STATUS=$(pct status "$CTID" | awk '{print $2}')

    echo -e "${CYAN}[LXC $CTID] $NAME${RESET}"

    if [[ "$STATUS" != "running" ]]; then
        echo -e "  ${RED}OFFLINE${RESET}"
        REPORT+="- LXC $CTID ($NAME) OFFLINE"$'\n'
        continue
    fi

    DISTRO=$(pct exec "$CTID" -- sh -c \
        "grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2")

    COUNT=0

    case "$DISTRO" in
        debian|ubuntu)
            timeout 20 pct exec "$CTID" -- apt-get update -qq
            COUNT=$(pct exec "$CTID" -- sh -c \
                "apt list --upgradable 2>/dev/null | tail -n +2 | wc -l")
            ;;
        alpine)
            timeout 20 pct exec "$CTID" -- apk update >/dev/null
            COUNT=$(pct exec "$CTID" -- sh -c \
                "apk list -u 2>/dev/null | wc -l")
            ;;
        arch)
            timeout 20 pct exec "$CTID" -- pacman -Sy --noconfirm >/dev/null
            COUNT=$(pct exec "$CTID" -- sh -c \
                "pacman -Qu 2>/dev/null | wc -l")
            ;;
        fedora|rhel|centos|rocky|almalinux)
            timeout 20 pct exec "$CTID" -- dnf -y makecache >/dev/null
            COUNT=$(pct exec "$CTID" -- sh -c \
                "dnf check-update 2>/dev/null | grep -E '^[a-zA-Z0-9]' | wc -l")
            ;;
        *)
            echo -e "  ${RED}Unsupported distro: $DISTRO${RESET}"
            REPORT+="- LXC $CTID ($NAME) unsupported ($DISTRO)"$'\n'
            continue
            ;;
    esac

    COUNT=${COUNT:-0}

    END=$(date +%s)
    DURATION=$((END - START))

    TOTAL_UPDATES=$((TOTAL_UPDATES + COUNT))

    if [[ "$COUNT" -ge "$HIGH_UPDATE_THRESHOLD" ]]; then
        IMPORTANT=true
        echo -e "  ${YELLOW}$COUNT updates (${DURATION}s) [HIGH]${RESET}"
        REPORT+="- LXC $CTID ($NAME) → **$COUNT updates**"$'\n'
    else
        echo -e "  ${GREEN}$COUNT updates (${DURATION}s)${RESET}"
        REPORT+="- LXC $CTID ($NAME) → $COUNT updates"$'\n'
    fi
done

# ---------------- VM ----------------

echo -e "\n=== VM Check ==="

for VMID in $(qm list | awk 'NR>1 {print $1}'); do
    START=$(date +%s)

    NAME=$(qm config "$VMID" | awk '/name:/ {print $2}')
    STATUS=$(qm status "$VMID" | awk '{print $2}')

    echo -e "${CYAN}[VM $VMID] $NAME${RESET}"

    if [[ "$STATUS" != "running" ]]; then
        echo -e "  ${RED}OFFLINE${RESET}"
        REPORT+="- VM $VMID ($NAME) OFFLINE"$'\n'
        continue
    fi

    AGENT=$(qm config "$VMID" | grep -q "agent:.*1" && echo yes)

    if [[ "$AGENT" != "yes" ]]; then
        echo -e "  ${YELLOW}no guest agent${RESET}"
        REPORT+="- VM $VMID ($NAME) no guest agent"$'\n'
        continue
    fi

    DISTRO=$(qm guest exec "$VMID" -- cat /etc/os-release 2>/dev/null \
        | grep -oP '"out-data":"\K[^"]+' \
        | grep '^ID=' \
        | head -1 \
        | cut -d= -f2)

    COUNT=0

    case "$DISTRO" in
        debian|ubuntu)
            timeout 20 qm guest exec "$VMID" -- \
                bash -c "apt-get update -qq"

            COUNT=$(qm guest exec "$VMID" -- \
                bash -c "apt list --upgradable 2>/dev/null | tail -n +2 | wc -l" \
                | grep -oP '"out-data":"\K[0-9]+')
            ;;
        fedora|rhel|centos|rocky|almalinux)
            timeout 20 qm guest exec "$VMID" -- \
                bash -c "dnf -y makecache" >/dev/null

            COUNT=$(qm guest exec "$VMID" -- \
                bash -c "dnf check-update 2>/dev/null | grep -E '^[a-zA-Z0-9]' | wc -l" \
                | grep -oP '"out-data":"\K[0-9]+')
            ;;
        *)
            echo -e "  ${YELLOW}unsupported distro${RESET}"
            REPORT+="- VM $VMID ($NAME) unsupported ($DISTRO)"$'\n'
            continue
            ;;
    esac

    COUNT=${COUNT:-0}

    END=$(date +%s)
    DURATION=$((END - START))

    TOTAL_UPDATES=$((TOTAL_UPDATES + COUNT))

    if [[ "$COUNT" -ge "$HIGH_UPDATE_THRESHOLD" ]]; then
        IMPORTANT=true
        echo -e "  ${YELLOW}$COUNT updates (${DURATION}s) [HIGH]${RESET}"
        REPORT+="- VM $VMID ($NAME) → **$COUNT updates**"$'\n'
    else
        echo -e "  ${GREEN}$COUNT updates (${DURATION}s)${RESET}"
        REPORT+="- VM $VMID ($NAME) → $COUNT updates"$'\n'
    fi
done

if [[ "$TOTAL_UPDATES" -ge "$TOTAL_THRESHOLD" ]]; then
    IMPORTANT=true
fi

REPORT+=$'\n'"Summary"$'\n'
REPORT+="- Total pending updates: $TOTAL_UPDATES"$'\n'

if [[ "$ONLY_NOTIFY_IF_IMPORTANT" == true && "$IMPORTANT" != true ]]; then
    echo "No important updates"
    exit 0
fi

if [[ "$ENABLE_NTFY" == true ]]; then
    curl -s \
        -H "Markdown: yes" \
        -H "Title: Proxmox Update Report" \
        -d "$REPORT" \
        "$NTFY_SERVER/$NTFY_TOPIC" > /dev/null

    echo -e "\n${GREEN}ntfy notification sent${RESET}"
fi

echo "=== Done ==="