
#!/bin/bash

# PROXMOX WEEKLY UPDATE SCRIPT


# CONFIG

NTFY_SERVER="https://ntfy.sh"
NTFY_TOPIC="YOUR_TOPIC"

LOG="/var/log/lxc-updater.log"
APT_TIMEOUT=600
MIN_DISK_MB=500


# FLAGS

VERBOSE=false

for arg in "$@"; do
    case $arg in
        -v|--verbose) VERBOSE=true ;;
    esac
done


# HELPERS

log() {
    echo "$(date '+%F %T') $1" >> "$LOG"
}

vlog() {
    [[ "$VERBOSE" == true ]] && echo -e "$1"
}

run_cmd() {
    "$@"
}


# INIT

HOST=$(hostname)
DATE=$(date "+%Y-%m-%d %H:%M")

echo "=== Weekly Update Run ==="

REPORT="## Proxmox Weekly Updates"$'\n'
REPORT+="Host: $HOST"$'\n'
REPORT+="Time: $DATE"$'\n\n'

UPDATED=""
REBOOTED=""
FAILED=""
OFFLINE=""
SKIPPED=""
NO_UPDATES=""


# LXC PROCESSING

process_lxc() {
    echo "--- Processing LXC ---"

    for CTID in $(pct list | awk 'NR>1 {print $1}'); do
        local START END DURATION COUNT DISTRO NAME STATUS FREE LOCK

        START=$(date +%s)
        NAME=$(pct config "$CTID" | awk '/hostname/ {print $2}')
        STATUS=$(pct status "$CTID" | awk '{print $2}')

        vlog "\n[LXC $CTID - $NAME]"

        if [[ "$STATUS" != "running" ]]; then
            OFFLINE+="- LXC $CTID ($NAME)"$'\n'
            vlog "  Status: OFFLINE"
            continue
        fi

        FREE=$(pct exec "$CTID" -- df -Pm / | awk 'NR==2 {print $4}')
        vlog "  Disk: ${FREE}MB free"

        if [[ "$FREE" -lt "$MIN_DISK_MB" ]]; then
            SKIPPED+="- LXC $CTID ($NAME) low disk (${FREE}MB)"$'\n'
            vlog "  Skipped: low disk"
            continue
        fi

        LOCK=$(pct exec "$CTID" -- bash -c "fuser /var/lib/dpkg/lock-frontend 2>/dev/null")
        if [[ -n "$LOCK" ]]; then
            SKIPPED+="- LXC $CTID ($NAME) apt locked"$'\n'
            vlog "  Skipped: apt locked"
            continue
        fi

        DISTRO=$(pct exec "$CTID" -- sh -c "grep '^ID=' /etc/os-release | cut -d= -f2")
        vlog "  Distro: $DISTRO"

        COUNT=0

        case "$DISTRO" in
            debian|ubuntu)
                vlog "  apt update..."
                timeout $APT_TIMEOUT pct exec "$CTID" -- apt-get update -qq

                COUNT=$(pct exec "$CTID" -- sh -c \
                    "apt list --upgradable 2>/dev/null | tail -n +2 | wc -l")

                vlog "  Updates: $COUNT"

                [[ "$COUNT" -gt 0 ]] && \
                    timeout $APT_TIMEOUT pct exec "$CTID" -- apt-get upgrade -y -qq
                ;;
            alpine)
                pct exec "$CTID" -- apk update >/dev/null
                COUNT=$(pct exec "$CTID" -- sh -c "apk list -u | wc -l")
                [[ "$COUNT" -gt 0 ]] && pct exec "$CTID" -- apk upgrade
                ;;
            arch)
                pct exec "$CTID" -- pacman -Sy --noconfirm >/dev/null
                COUNT=$(pct exec "$CTID" -- sh -c "pacman -Qu | wc -l")
                [[ "$COUNT" -gt 0 ]] && pct exec "$CTID" -- pacman -Su --noconfirm
                ;;
            *)
                SKIPPED+="- LXC $CTID ($NAME) unsupported ($DISTRO)"$'\n'
                vlog "  Unsupported distro"
                continue
                ;;
        esac

        END=$(date +%s)
        DURATION=$((END - START))

        if [[ "$COUNT" -eq 0 ]]; then
            NO_UPDATES+="- LXC $CTID ($NAME) no updates"$'\n'
        else
            UPDATED+="- LXC $CTID ($NAME) → $COUNT updates (${DURATION}s)"$'\n'
        fi

        if pct exec "$CTID" -- test -f /var/run/reboot-required; then
            pct reboot "$CTID"
            REBOOTED+="- LXC $CTID ($NAME)"$'\n'
            vlog "  Rebooted"
        fi

        log "LXC $CTID processed ($COUNT updates)"
    done
}


# VM PROCESSING

process_vm() {
    echo "--- Processing VMs ---"

    for VMID in $(qm list | awk 'NR>1 {print $1}'); do
        local START END DURATION COUNT DISTRO NAME STATUS AGENT

        NAME=$(qm config "$VMID" | awk '/name:/ {print $2}')
        STATUS=$(qm status "$VMID" | awk '{print $2}')

        vlog "\n[VM $VMID - $NAME]"

        AGENT=$(qm config "$VMID" | grep -q "agent: 1" && echo "yes")

        if [[ "$AGENT" != "yes" ]]; then
            SKIPPED+="- VM $VMID ($NAME) no agent"$'\n'
            vlog "  Skipped: no agent"
            continue
        fi

        if [[ "$STATUS" != "running" ]]; then
            OFFLINE+="- VM $VMID ($NAME)"$'\n'
            vlog "  Status: OFFLINE"
            continue
        fi

        START=$(date +%s)

        DISTRO=$(qm guest exec "$VMID" -- sh -c \
            "grep '^ID=' /etc/os-release | cut -d= -f2" 2>/dev/null)

        vlog "  Distro: $DISTRO"

        COUNT=0

        case "$DISTRO" in
            debian|ubuntu)
                timeout $APT_TIMEOUT qm guest exec "$VMID" -- \
                    bash -c "apt-get update -qq"

                COUNT=$(qm guest exec "$VMID" -- \
                    bash -c "apt list --upgradable 2>/dev/null | tail -n +2 | wc -l")

                vlog "  Updates: $COUNT"

                [[ "$COUNT" -gt 0 ]] && \
                    timeout $APT_TIMEOUT qm guest exec "$VMID" -- \
                    bash -c "apt-get upgrade -y -qq"
                ;;
            *)
                SKIPPED+="- VM $VMID ($NAME) unsupported ($DISTRO)"$'\n'
                vlog "  Unsupported distro"
                continue
                ;;
        esac

        END=$(date +%s)
        DURATION=$((END - START))

        if [[ "$COUNT" -eq 0 ]]; then
            NO_UPDATES+="- VM $VMID ($NAME) no updates"$'\n'
        else
            UPDATED+="- VM $VMID ($NAME) → $COUNT updates (${DURATION}s)"$'\n'
        fi

        if qm guest exec "$VMID" -- test -f /var/run/reboot-required; then
            qm reboot "$VMID"
            REBOOTED+="- VM $VMID ($NAME)"$'\n'
            vlog "  Rebooted"
        fi

        log "VM $VMID processed ($COUNT updates)"
    done
}


# RUN

process_lxc
process_vm


# REPORT

[[ -n "$UPDATED" ]] && REPORT+="Updated"$'\n'"$UPDATED"$'\n'
[[ -n "$NO_UPDATES" ]] && REPORT+="No Updates"$'\n'"$NO_UPDATES"$'\n'
[[ -n "$REBOOTED" ]] && REPORT+="Rebooted"$'\n'"$REBOOTED"$'\n'
[[ -n "$SKIPPED" ]] && REPORT+="Skipped"$'\n'"$SKIPPED"$'\n'
[[ -n "$OFFLINE" ]] && REPORT+="Offline"$'\n'"$OFFLINE"$'\n'

curl -s \
  -H "Markdown: yes" \
  -H "Title: Proxmox Weekly Updates" \
  -d "$REPORT" \
  "$NTFY_SERVER/$NTFY_TOPIC" > /dev/null

echo "$REPORT"
echo "=== Done ==="