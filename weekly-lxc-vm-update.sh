#!/bin/bash

#############################################
# Proxmox LXC + VM Weekly Update Script
#############################################

NTFY_SERVER="https://ntfy.sh"
NTFY_TOPIC="YOUR_TOPIC"

LOG="/var/log/lxc-updater.log"

APT_TIMEOUT=600
MIN_DISK_MB=500

HOST=$(hostname)
DATE=$(date "+%Y-%m-%d %H:%M")

log() {
    echo "$(date '+%F %T') $1" >> "$LOG"
}

REPORT="## Proxmox Weekly Updates
**Host:** $HOST
**Time:** $DATE

"

UPDATED=""
REBOOTED=""
FAILED=""
OFFLINE=""

#############################################
# LXC PROCESSING
#############################################

for CTID in $(pct list | awk 'NR>1 {print $1}')
do
    START=$(date +%s)

    NAME=$(pct config "$CTID" | awk '/hostname/ {print $2}')
    STATUS=$(pct status "$CTID" | awk '{print $2}')

    log "LXC $CTID ($NAME) status: $STATUS"

    if [[ "$STATUS" != "running" ]]; then
        OFFLINE+="- LXC $CTID ($NAME)\n"
        continue
    fi

    # Disk check
    FREE=$(pct exec "$CTID" -- df -Pm / | awk 'NR==2 {print $4}')
    if [[ "$FREE" -lt "$MIN_DISK_MB" ]]; then
        FAILED+="- LXC $CTID ($NAME) low disk (${FREE}MB)\n"
        continue
    fi

    # APT lock check
    LOCK=$(pct exec "$CTID" -- bash -c "fuser /var/lib/dpkg/lock-frontend 2>/dev/null")
    if [[ -n "$LOCK" ]]; then
        FAILED+="- LXC $CTID ($NAME) apt locked\n"
        continue
    fi

    # Update
    timeout "$APT_TIMEOUT" pct exec "$CTID" -- apt-get update -qq
    if [[ $? -ne 0 ]]; then
        FAILED+="- LXC $CTID ($NAME) update failed\n"
        continue
    fi

    # Get upgrade list
    PKGS=$(pct exec "$CTID" -- bash -c "apt list --upgradable 2>/dev/null | tail -n +2 | cut -d/ -f1")
    COUNT=$(echo "$PKGS" | grep -c .)

    if [[ "$COUNT" -eq 0 ]]; then
        continue
    fi

    # Upgrade
    timeout "$APT_TIMEOUT" pct exec "$CTID" -- apt-get upgrade -y -qq
    if [[ $? -ne 0 ]]; then
        FAILED+="- LXC $CTID ($NAME) upgrade failed\n"
        continue
    fi

    # Reboot detection
    if pct exec "$CTID" -- test -f /var/run/reboot-required; then
        pct reboot "$CTID"
        REBOOTED+="- LXC $CTID ($NAME)\n"
    fi

    END=$(date +%s)
    DURATION=$((END - START))

    UPDATED+="- LXC $CTID ($NAME) → $COUNT packages (${DURATION}s)\n"

    log "LXC $CTID updated: $COUNT packages in ${DURATION}s"
done

#############################################
# VM PROCESSING (QEMU AGENT)
#############################################

for VMID in $(qm list | awk 'NR>1 {print $1}')
do
    NAME=$(qm config "$VMID" | awk '/name:/ {print $2}')
    STATUS=$(qm status "$VMID" | awk '{print $2}')

    AGENT=$(qm config "$VMID" | grep -q "agent: 1" && echo "yes")

    if [[ "$AGENT" != "yes" ]]; then
        continue
    fi

    log "VM $VMID ($NAME) status: $STATUS"

    if [[ "$STATUS" != "running" ]]; then
        OFFLINE+="- VM $VMID ($NAME)\n"
        continue
    fi

    START=$(date +%s)

    timeout "$APT_TIMEOUT" qm guest exec "$VMID" -- bash -c "apt-get update -qq && apt-get upgrade -y -qq"
    if [[ $? -ne 0 ]]; then
        FAILED+="- VM $VMID ($NAME) update failed\n"
        continue
    fi

    if qm guest exec "$VMID" -- test -f /var/run/reboot-required; then
        qm reboot "$VMID"
        REBOOTED+="- VM $VMID ($NAME)\n"
    fi

    END=$(date +%s)
    DURATION=$((END - START))

    UPDATED+="- VM $VMID ($NAME) updated (${DURATION}s)\n"

    log "VM $VMID updated in ${DURATION}s"
done

#############################################
# SEND REPORT
#############################################

REPORT+="### Updated
$UPDATED

### Rebooted
$REBOOTED

### Failed
$FAILED

### Offline
$OFFLINE
"

curl -s \
  -H "Markdown: yes" \
  -H "Title: Proxmox Weekly Updates" \
  -d "$REPORT" \
  "$NTFY_SERVER/$NTFY_TOPIC" > /dev/null

log "Weekly update completed"