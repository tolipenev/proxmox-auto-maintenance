#!/bin/bash

NTFY_SERVER="https://ntfy.sh"
NTFY_TOPIC="YOUR_TOPIC"

HOST=$(hostname)
DATE=$(date "+%Y-%m-%d %H:%M")

REPORT="## Proxmox Backup Status
**Host:** $HOST
**Time:** $DATE

"

TASKS=$(pvesh get /nodes/$(hostname)/tasks --limit 50 --output-format json | jq -r '.[] | select(.type=="vzdump") | "\(.status) \(.id)"')

SUCCESS=""
FAILED=""

while read -r line
do
    STATUS=$(echo "$line" | awk '{print $1}')
    TASK=$(echo "$line" | awk '{print $2}')

    if [[ "$STATUS" == "OK" ]]; then
        SUCCESS+="- $TASK\n"
    else
        FAILED+="- $TASK\n"
    fi
done <<< "$TASKS"

REPORT+="### Successful Backups
$SUCCESS

### Failed Backups
$FAILED
"

curl -s \
  -H "Markdown: yes" \
  -H "Title: Proxmox Backup Report" \
  -d "$REPORT" \
  "$NTFY_SERVER/$NTFY_TOPIC" > /dev/null