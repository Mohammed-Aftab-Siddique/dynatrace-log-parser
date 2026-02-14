#!/usr/bin/env bash
set -euo pipefail

# Configuration
LOG_DIR="<Log Directory Path>"
LOG_FILE="<Log File Name>"
STATE_FILE="$PWD/state/.log_parser_last_ts"
HOST_IP="<Host IP>"

DYNATRACE_URL="https://<Environment ID>.live.dynatrace.com"
API_TOKEN="<API Token with Ingest.Metrics permission ONLY>"

KEYWORDS=(
  "Keyword 1"
  "Keyword 2"
  "Keyword 3"
  ...
)

# Load last processed timestamp
last_ts="1970-01-01 00:00:00"
if [[ -f "$STATE_FILE" ]]; then
  last_ts=$(cat "$STATE_FILE")
fi

# Find latest matching log file
latest_log_file=$(ls -t "$LOG_DIR"/*"$LOG_FILE"* 2>/dev/null | head -n 1 || true)

if [[ -z "$latest_log_file" || ! -f "$latest_log_file" ]]; then
  echo "No matching log file found"
  exit 0
fi

# Parse log file incrementally
declare -A COUNTS
newest_ts="$last_ts"
match_found=false

while IFS= read -r line; do
  # Extract timestamp (first 19 chars: YYYY-MM-DD HH:MM:SS)
  line_ts="${line:0:19}"

  # Skip malformed or old entries
  if [[ "$line_ts" < "$last_ts" || "$line_ts" == "$last_ts" ]]; then
    continue
  fi

  # Track newest timestamp seen
  if [[ $line_ts =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] && [[ "$line_ts" > "$newest_ts" ]]; then
    newest_ts="$line_ts"
  fi

  for keyword in "${KEYWORDS[@]}"; do
    if [[ "$line" == *"$keyword"* ]]; then

      if [[ "$line" =~ \[([^]]+)\] ]]; then
        path="${BASH_REMATCH[1]}"
        service="${path##*/}"
        
        if [[ "$service" =~ ^[a-zA-Z0-9_-]+$ ]]; then
          COUNTS["$service"]=$(( ${COUNTS["$service"]:-0} + 1 ))
          match_found=true
        fi
        
      fi

      break
    fi
  done
done < "$latest_log_file"

# Exit if nothing new found
if [[ "$match_found" == false ]]; then
  echo "No new matching log entries found"
  exit 0
fi

# Build Dynatrace delta payload
payload=""
for service in "${!COUNTS[@]}"; do
  payload+="custom.sam.log.error,host=${HOST_IP},dir=${LOG_DIR},service=${service} count,delta=${COUNTS[$service]}"$'\n'
done

# Push metrics
curl -s -X POST "$DYNATRACE_URL/api/v2/metrics/ingest" \
  -H "Authorization: Api-Token $API_TOKEN" \
  -H "Content-Type: text/plain; charset=utf-8" \
  --data-binary "$payload"

# Persist newest processed timestamp
echo "$newest_ts" > "$STATE_FILE"

