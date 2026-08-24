#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/config.sh"
CONFIG_FILE="config.json"

YEARS=(2000 2014 2015)

PERIODS=(
  "03-31:02-15"
  "05-31:04-15"
  "08-31:07-15"
)

for year in "${YEARS[@]}"; do
  for period in "${PERIODS[@]}"; do
    start="${period%%:*}"
    end="${period##*:}"

    date_start="${year}-${start} 23:00:00"
    date_end="${year}-${end} 00:00:00"

    notify "=== Starting run: ${date_start} -> ${date_end} ==="

    tmp_json=$(mktemp)
    jq --arg ds "$date_start" --arg de "$date_end" \
       '.date_start = $ds | .date_end = $de' "$CONFIG_FILE" > "$tmp_json"
    mv "$tmp_json" "$CONFIG_FILE"

    ".$SCRIPTS_DIR/execution.sh"

    echo "=== Run finished ==="
  done
done