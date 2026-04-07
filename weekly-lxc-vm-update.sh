#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

LOCKFILE="/var/run/proxmox-weekly-update.lock"
exec 200>$LOCKFILE
flock -n 200 || exit 0

# CONFIG
NTFY_SERVER="https://ntfy.techhome.app"
NTFY_TOPIC="Weekly_P1"

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

log() {
    echo "$(date '+%F %T') $1" >> "$LOG"
}

vlog() {
    [[ "$VERBOSE" == true ]] && echo -e "$1"
}

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

# ---------------- LXC ----------------

process_lxc() {
    echo "--- Processing LXC ---"

    for CTID in $(pct list | awk 'NR>1 {print $1}'); do
        START=$(date +%s)

        NAME=$(pct config "$CTID" | awk '/hostname/ {print $2}')
        STATUS=$(pct status "$CTID" | awk '{print $2}')

        vlog "\n[LXC $CTID - $NAME]"

        if [[ "$STATUS" != "running" ]]; then
            OFFLINE+="- LXC $CTID ($NAME)"$'\n'
            continue
        fi

        FREE=$(pct exec "$CTID" -- df -Pm / | awk 'NR==2 {print $4}')

        if [[ "$FREE" -lt "$MIN_DISK_MB" ]]; then
            SKIPPED+="- LXC $CTID ($NAME) low disk (${FREE}MB)"$'\n'
            continue
        fi

        DISTRO=$(pct exec "$CTID" -- sh -c "grep '^ID=' /etc/os-release | cut -d= -f2")

        COUNT=0
        RC=0

        case "$DISTRO" in
            debian|ubuntu)
                LOCK=$(pct exec "$CTID" -- sh -c \
                "fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null")

                [[ -n "$LOCK" ]] && {
                    SKIPPED+="- LXC $CTID ($NAME) apt locked"$'\n'
                    continue
                }

                timeout $APT_TIMEOUT pct exec "$CTID" -- apt-get update -qq
                RC=$?

                COUNT=$(pct exec "$CTID" -- sh -c \
                    "apt list --upgradable 2>/dev/null | tail -n +2 | wc -l")

                [[ "$COUNT" -gt 0 ]] && \
                    timeout $APT_TIMEOUT pct exec "$CTID" -- apt-get upgrade -y -qq
                ;;

            alpine)
                timeout $APT_TIMEOUT pct exec "$CTID" -- apk update
                RC=$?

                COUNT=$(pct exec "$CTID" -- sh -c "apk list -u | wc -l")

                [[ "$COUNT" -gt 0 ]] && \
                    timeout $APT_TIMEOUT pct exec "$CTID" -- apk upgrade
                ;;

            arch)
                timeout $APT_TIMEOUT pct exec "$CTID" -- pacman -Sy --noconfirm
                RC=$?

                COUNT=$(pct exec "$CTID" -- sh -c "pacman -Qu | wc -l")

                [[ "$COUNT" -gt 0 ]] && \
                    timeout $APT_TIMEOUT pct exec "$CTID" -- pacman -Su --noconfirm
                ;;

            fedora|rhel|centos|rocky|almalinux)
                timeout $APT_TIMEOUT pct exec "$CTID" -- dnf -y makecache
                RC=$?

                COUNT=$(pct exec "$CTID" -- sh -c \
                    "dnf check-update 2>/dev/null | grep -E '^[a-zA-Z0-9]' | wc -l")

                [[ "$COUNT" -gt 0 ]] && \
                    timeout $APT_TIMEOUT pct exec "$CTID" -- dnf upgrade -y -q
                ;;

            *)
                SKIPPED+="- LXC $CTID ($NAME) unsupported ($DISTRO)"$'\n'
                continue
                ;;
        esac

        END=$(date +%s)
        DURATION=$((END - START))

        if [[ "$RC" -ne 0 ]]; then
            FAILED+="- LXC $CTID ($NAME) update failed"$'\n'
            continue
        fi

        if [[ "$COUNT" -eq 0 ]]; then
            NO_UPDATES+="- LXC $CTID ($NAME)"$'\n'
        else
            UPDATED+="- LXC $CTID ($NAME) → $COUNT updates (${DURATION}s)"$'\n'
        fi

        if pct exec "$CTID" -- sh -c '[ -f /var/run/reboot-required ]'; then
            pct reboot "$CTID"
            REBOOTED+="- LXC $CTID ($NAME)"$'\n'
        fi

        log "LXC $CTID processed ($COUNT updates)"
    done
}

# ---------------- VM ----------------

process_vm() {
    echo "--- Processing VMs ---"

    for VMID in $(qm list | awk 'NR>1 {print $1}'); do
        NAME=$(qm config "$VMID" | awk '/name:/ {print $2}')
        STATUS=$(qm status "$VMID" | awk '{print $2}')

        AGENT=$(qm config "$VMID" | grep -q "agent:.*1" && echo yes)

        [[ "$AGENT" != "yes" ]] && {
            SKIPPED+="- VM $VMID ($NAME) no agent"$'\n'
            continue
        }

        [[ "$STATUS" != "running" ]] && {
            OFFLINE+="- VM $VMID ($NAME)"$'\n'
            continue
        }

        START=$(date +%s)

        DISTRO=$(qm guest exec "$VMID" -- cat /etc/os-release 2>/dev/null \
        | grep -oP '"out-data":"\K[^"]+' \
        | grep '^ID=' \
        | head -1 \
        | cut -d= -f2)

        COUNT=0
        RC=0

        case "$DISTRO" in
            debian|ubuntu)
                timeout $APT_TIMEOUT qm guest exec "$VMID" -- \
                    bash -c "apt-get update -qq"
                RC=$?

                COUNT=$(qm guest exec "$VMID" -- \
                    bash -c "apt list --upgradable 2>/dev/null | tail -n +2 | wc -l" \
                    | grep -oP '"out-data":"\K[0-9]+')

                [[ "$COUNT" -gt 0 ]] && \
                    timeout $APT_TIMEOUT qm guest exec "$VMID" -- \
                    bash -c "apt-get upgrade -y -qq"
                ;;

            fedora|rhel|centos|rocky|almalinux)
                timeout $APT_TIMEOUT qm guest exec "$VMID" -- \
                    bash -c "dnf -y makecache"
                RC=$?

                COUNT=$(qm guest exec "$VMID" -- \
                    bash -c "dnf check-update 2>/dev/null | grep -E '^[a-zA-Z0-9]' | wc -l" \
                    | grep -oP '"out-data":"\K[0-9]+')

                [[ "$COUNT" -gt 0 ]] && \
                    timeout $APT_TIMEOUT qm guest exec "$VMID" -- \
                    bash -c "dnf upgrade -y -q"
                ;;

            *)
                SKIPPED+="- VM $VMID ($NAME) unsupported ($DISTRO)"$'\n'
                continue
                ;;
        esac

        COUNT=${COUNT:-0}
        END=$(date +%s)
        DURATION=$((END - START))

        if [[ "$RC" -ne 0 ]]; then
            FAILED+="- VM $VMID ($NAME) update failed"$'\n'
            continue
        fi

        if [[ "$COUNT" -eq 0 ]]; then
            NO_UPDATES+="- VM $VMID ($NAME)"$'\n'
        else
            UPDATED+="- VM $VMID ($NAME) → $COUNT updates (${DURATION}s)"$'\n'
        fi

        if qm guest exec "$VMID" -- sh -c '[ -f /var/run/reboot-required ]' \
            | grep -q '"exitcode":0'; then
            qm reboot "$VMID"
            REBOOTED+="- VM $VMID ($NAME)"$'\n'
        fi

        log "VM $VMID processed ($COUNT updates)"
    done
}

process_lxc
process_vm

REPORT+=$'\n'"Summary"$'\n'

[[ -n "$UPDATED" ]] && REPORT+=$'\n'"Updated"$'\n'"$UPDATED"
[[ -n "$REBOOTED" ]] && REPORT+=$'\n'"Rebooted"$'\n'"$REBOOTED"
[[ -n "$NO_UPDATES" ]] && REPORT+=$'\n'"No Updates"$'\n'"$NO_UPDATES"
[[ -n "$SKIPPED" ]] && REPORT+=$'\n'"Skipped"$'\n'"$SKIPPED"
[[ -n "$FAILED" ]] && REPORT+=$'\n'"Failed"$'\n'"$FAILED"
[[ -n "$OFFLINE" ]] && REPORT+=$'\n'"Offline"$'\n'"$OFFLINE"

curl -s \
  -H "Markdown: yes" \
  -H "Title: Proxmox Weekly Updates" \
  -d "$REPORT" \
  "$NTFY_SERVER/$NTFY_TOPIC" > /dev/null

echo "$REPORT"
echo "=== Done ==="