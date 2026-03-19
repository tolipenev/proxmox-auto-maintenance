#!/bin/bash

#  CONFIG
NTFY_SERVER="https://ntfy.sh"
NTFY_TOPIC="YOUR_TOPIC"
ENABLE_NTFY=true

PBS_REPO="user@pam@IP/DOMAIN:prox-backups"
PBS_NAMESPACES=("proxmox1" "proxmox2")

MAX_AGE_HOURS=24
STORAGE_WARN_THRESHOLD=80

# AUTH
export PBS_PASSWORD=$(cat /root/.pbs_pass)

#  INIT
HOST=$(hostname)
DATE=$(date "+%Y-%m-%d %H:%M")
NOW=$(date +%s)
MAX_AGE=$((MAX_AGE_HOURS * 3600))

declare -A LAST_BACKUP

echo "=== PBS Backup Check ==="

#  FETCH SNAPSHOTS
for NS in "${PBS_NAMESPACES[@]}"; do
    echo "Checking namespace: $NS"

    SNAP_JSON=$(timeout 15 proxmox-backup-client snapshot list \
        --repository "$PBS_REPO" \
        --ns "$NS" \
        --output-format json 2>/dev/null)

    [[ -z "$SNAP_JSON" ]] && continue

    while read -r snap; do
        VMID=$(echo "$snap" | jq -r '."backup-id"')
        TS=$(echo "$snap" | jq -r '."backup-time"')

        [[ "$VMID" == "null" || "$TS" == "null" ]] && continue

        if [[ -z "${LAST_BACKUP[$VMID]}" || "${LAST_BACKUP[$VMID]}" -lt "$TS" ]]; then
            LAST_BACKUP[$VMID]=$TS
        fi
    done < <(echo "$SNAP_JSON" | jq -c '.[]')

done

#  CHECK VMS
OK_COUNT=0
MISSED_COUNT=0

OK_LIST=""
MISSED_LIST=""

for ID in $(qm list | awk 'NR>1 {print $1}'; pct list | awk 'NR>1 {print $1}'); do
    LAST=${LAST_BACKUP[$ID]}

    if [[ -z "$LAST" ]]; then
        echo "$ID -> NO BACKUP"
        MISSED_LIST+="- $ID (no backup)"$'\n'
        ((MISSED_COUNT++))
        continue
    fi

    AGE=$((NOW - LAST))
    HOURS=$((AGE / 3600))

    if [[ "$AGE" -gt "$MAX_AGE" ]]; then
        echo "$ID -> OLD (${HOURS}h)"
        MISSED_LIST+="- $ID (${HOURS}h old)"$'\n'
        ((MISSED_COUNT++))
    else
        echo "$ID -> OK (${HOURS}h)"
        OK_LIST+="- $ID OK (${HOURS}h)"$'\n'
        ((OK_COUNT++))
    fi
done

#  STORAGE
STORAGE_WARNINGS=""

while read -r line; do
    NAME=$(echo "$line" | awk '{print $1}')
    USED=$(echo "$line" | grep -oE '[0-9]+%' | tr -d '%')

    [[ "$NAME" == "Name" ]] && continue

    if [[ "$USED" =~ ^[0-9]+$ ]] && [[ "$USED" -ge "$STORAGE_WARN_THRESHOLD" ]]; then
        STORAGE_WARNINGS+="- $NAME at ${USED}%"$'\n'
    fi
done < <(pvesm status)

#  REPORT
REPORT="## Proxmox Backup Status"$'\n'
REPORT+="Host: $HOST"$'\n'
REPORT+="Time: $DATE"$'\n\n'

REPORT+="Summary"$'\n'
REPORT+="- OK: $OK_COUNT"$'\n'
REPORT+="- Missed: $MISSED_COUNT"$'\n\n'

[[ -n "$OK_LIST" ]] && REPORT+="Healthy"$'\n'"$OK_LIST"$'\n'
[[ -n "$MISSED_LIST" ]] && REPORT+="Missing"$'\n'"$MISSED_LIST"$'\n'
[[ -n "$STORAGE_WARNINGS" ]] && REPORT+="Storage"$'\n'"$STORAGE_WARNINGS"$'\n'

#  NTFY
if [[ "$ENABLE_NTFY" == true ]]; then
    curl -s \
        -H "Markdown: yes" \
        -H "Title: Proxmox Backup Report" \
        -d "$REPORT" \
        "$NTFY_SERVER/$NTFY_TOPIC" > /dev/null
fi

echo "=== Done ==="