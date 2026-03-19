```bash
#!/bin/bash


# NTFY CONFIG

NTFY_SERVER="https://ntfy.sh"
NTFY_TOPIC="YOUR_TOPIC"
ENABLE_NTFY=true


# PBS CONFIG

PBS_REPO="root@pam@IP:prox-backups"
PBS_PASSWORD_FILE="/root/.pbs_pass"

export PBS_REPOSITORY="$PBS_REPO"
export PBS_PASSWORD_FILE="$PBS_PASSWORD_FILE"


# VALIDATION

[[ -z "$PBS_REPOSITORY" ]] && { echo "ERROR: PBS_REPOSITORY empty"; exit 1; }
[[ ! -f "$PBS_PASSWORD_FILE" ]] && { echo "ERROR: PBS password file missing"; exit 1; }


# SETTINGS

MAX_AGE_HOURS=24
MAX_AGE=$((MAX_AGE_HOURS * 3600))


# INIT

HOST=$(hostname)
DATE=$(date "+%Y-%m-%d %H:%M")
NOW=$(date +%s)

declare -A LAST_BACKUP

echo "=== PBS Backup Check ==="


# DISCOVER NAMESPACES

echo "Discovering namespaces..."

PBS_NAMESPACES=()

NAMESPACE_RAW=$(proxmox-backup-client namespace list 2>&1)

if [[ $? -ne 0 ]]; then
    echo "ERROR: namespace list failed:"
    echo "$NAMESPACE_RAW"
    exit 1
fi

while read -r ns; do
    [[ -n "$ns" ]] && PBS_NAMESPACES+=("$ns")
done <<< "$NAMESPACE_RAW"

[[ ${#PBS_NAMESPACES[@]} -eq 0 ]] && PBS_NAMESPACES=("")

echo "Found namespaces: ${PBS_NAMESPACES[*]}"


# FETCH SNAPSHOTS

fetch_snapshots() {
    local NS="$1"

    if [[ -n "$NS" ]]; then
        echo "Checking namespace: $NS"
        SNAP_JSON=$(proxmox-backup-client snapshot list --ns "$NS" --output-format json 2>/dev/null)
    else
        echo "Checking root namespace"
        SNAP_JSON=$(proxmox-backup-client snapshot list --output-format json 2>/dev/null)
    fi

    [[ -z "$SNAP_JSON" ]] && return

    while read -r snap; do
        VMID=$(echo "$snap" | jq -r '."backup-id"')
        TS=$(echo "$snap" | jq -r '."backup-time"')

        [[ "$VMID" == "null" || "$TS" == "null" ]] && continue

        KEY="${NS}:${VMID}"

        if [[ -z "${LAST_BACKUP[$KEY]}" || $((10#${LAST_BACKUP[$KEY]})) -lt $((10#$TS)) ]]; then
            LAST_BACKUP[$KEY]=$TS
        fi
    done < <(echo "$SNAP_JSON" | jq -c '.[]')
}

# Run fetch
for NS in "${PBS_NAMESPACES[@]}"; do
    fetch_snapshots "$NS"
done


# REPORT

REPORT="## Proxmox Backup Status"$'\n'
REPORT+="Host: $HOST"$'\n'
REPORT+="Time: $DATE"$'\n\n'

OK=0
OLD=0

for KEY in "${!LAST_BACKUP[@]}"; do
    NS="${KEY%%:*}"
    ID="${KEY##*:}"
    TS="${LAST_BACKUP[$KEY]}"

    AGE=$((NOW - 10#$TS))
    HOURS=$((AGE / 3600))

    if [[ "$AGE" -gt "$MAX_AGE" ]]; then
        REPORT+="- [$NS] $ID → OLD (${HOURS}h)"$'\n'
        ((OLD++))
    else
        REPORT+="- [$NS] $ID → OK (${HOURS}h)"$'\n'
        ((OK++))
    fi
done

REPORT+=$'\n'"Summary"$'\n'
REPORT+="- OK: $OK"$'\n'
REPORT+="- Old: $OLD"$'\n'


# NTFY

if [[ "$ENABLE_NTFY" == true ]]; then
    curl -s \
        -H "Markdown: yes" \
        -H "Title: PBS Backup Report" \
        -d "$REPORT" \
        "$NTFY_SERVER/$NTFY_TOPIC" > /dev/null
fi

echo "$REPORT"
echo "=== Done ==="
```
