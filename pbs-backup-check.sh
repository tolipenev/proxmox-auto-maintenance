#!/bin/bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

LOCKFILE="/var/run/pbs-health-check.lock"
exec 200>$LOCKFILE
flock -n 200 || exit 0

# ---------------- CONFIG ----------------

NTFY_SERVER="https://ntfy.sh"
NTFY_TOPIC="YOUR_TOPIC"
ENABLE_NTFY=true

PBS_REPO="root@pam@IP:prox-backups"
PBS_PASSWORD_FILE="/root/.pbs_pass"

MAX_AGE_HOURS=24
MAX_AGE=$((MAX_AGE_HOURS * 3600))

DATASTORE_WARN=80
DATASTORE_CRIT=90

DISK_WARN=80
DISK_CRIT=90

# ---------------- INIT ----------------

export PBS_REPOSITORY="$PBS_REPO"
export PBS_PASSWORD_FILE="$PBS_PASSWORD_FILE"

HOST=$(hostname)
DATE=$(date "+%Y-%m-%d %H:%M")
NOW=$(date +%s)

declare -A LAST_BACKUP

REPORT="## PBS Health Report"$'\n'
REPORT+="Host: $HOST"$'\n'
REPORT+="Time: $DATE"$'\n\n'

# ---------------- BACKUP CHECK ----------------

REPORT+="Backups"$'\n'

SNAP_JSON=$(timeout 30 proxmox-backup-client snapshot list --output-format json 2>/dev/null)

if [[ -z "$SNAP_JSON" ]]; then
    REPORT+="- FAILED: cannot read snapshots"$'\n'
else
    while read -r snap; do
        ID=$(echo "$snap" | jq -r '."backup-id"')
        TS=$(echo "$snap" | jq -r '."backup-time"')

        [[ "$ID" == "null" ]] && continue

        if [[ -z "${LAST_BACKUP[$ID]}" || ${LAST_BACKUP[$ID]} -lt $TS ]]; then
            LAST_BACKUP[$ID]=$TS
        fi

    done < <(echo "$SNAP_JSON" | jq -c '.[]')

    for ID in "${!LAST_BACKUP[@]}"; do
        TS=${LAST_BACKUP[$ID]}
        AGE=$((NOW - TS))
        H=$((AGE/3600))

        if [[ $AGE -gt $MAX_AGE ]]; then
            REPORT+="- $ID OLD (${H}h)"$'\n'
        else
            REPORT+="- $ID OK (${H}h)"$'\n'
        fi
    done
fi

# ---------------- VERIFY CHECK ----------------

REPORT+=$'\n'"Verify"$'\n'

VERIFY=$(timeout 30 proxmox-backup-manager task list --type verify --output-format json 2>/dev/null)

if [[ -z "$VERIFY" ]]; then
    REPORT+="- no verify jobs found"$'\n'
else
    LAST_VERIFY=$(echo "$VERIFY" | jq -r '.[0].endtime // empty')

    if [[ -n "$LAST_VERIFY" ]]; then
        AGE=$((NOW - LAST_VERIFY))
        H=$((AGE/3600))

        if [[ $AGE -gt $MAX_AGE ]]; then
            REPORT+="- verify OLD (${H}h)"$'\n'
        else
            REPORT+="- verify OK (${H}h)"$'\n'
        fi
    else
        REPORT+="- verify never run"$'\n'
    fi
fi

# ---------------- PRUNE CHECK ----------------

REPORT+=$'\n'"Prune"$'\n'

PRUNE=$(timeout 30 proxmox-backup-manager task list --type prune --output-format json 2>/dev/null)

if [[ -z "$PRUNE" ]]; then
    REPORT+="- no prune jobs found"$'\n'
else
    LAST_PRUNE=$(echo "$PRUNE" | jq -r '.[0].endtime // empty')

    if [[ -n "$LAST_PRUNE" ]]; then
        AGE=$((NOW - LAST_PRUNE))
        H=$((AGE/3600))

        if [[ $AGE -gt $MAX_AGE ]]; then
            REPORT+="- prune OLD (${H}h)"$'\n'
        else
            REPORT+="- prune OK (${H}h)"$'\n'
        fi
    else
        REPORT+="- prune never run"$'\n'
    fi
fi

# ---------------- DATASTORE CHECK ----------------

REPORT+=$'\n'"Datastore"$'\n'

while read -r ds; do
    NAME=$(echo "$ds" | jq -r '.name')
    USED=$(echo "$ds" | jq -r '.used')
    TOTAL=$(echo "$ds" | jq -r '.total')

    [[ "$TOTAL" -eq 0 ]] && continue

    PCT=$(( USED * 100 / TOTAL ))

    if [[ $PCT -ge $DATASTORE_CRIT ]]; then
        REPORT+="- $NAME CRITICAL ${PCT}%"$'\n'
    elif [[ $PCT -ge $DATASTORE_WARN ]]; then
        REPORT+="- $NAME WARN ${PCT}%"$'\n'
    else
        REPORT+="- $NAME OK ${PCT}%"$'\n'
    fi

done < <(echo "$DATASTORE" | jq -c '.[]')

# ---------------- DISK CHECK ----------------

REPORT+=$'\n'"PBS Disk"$'\n'

PCT=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')

    if [[ $PCT -ge $DISK_CRIT ]]; then
        REPORT+="- disk CRITICAL ${PCT}%"$'\n'
    elif [[ $PCT -ge $DISK_WARN ]]; then
        REPORT+="- disk WARN ${PCT}%"$'\n'
    else
        REPORT+="- disk OK ${PCT}%"$'\n'
    fi
done

# ---------------- SEND ----------------

curl -s \
  -H "Markdown: yes" \
  -H "Title: PBS Health Report" \
  -d "$REPORT" \
  "$NTFY_SERVER/$NTFY_TOPIC" > /dev/null

echo "$REPORT"