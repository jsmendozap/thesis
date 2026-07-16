#!/bin/bash
set -e

export PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DATA_DIR="$PROJECT_DIR/data"
export OUTPUT_DIR="$PROJECT_DIR/output"
export RUN_DIR="$PROJECT_DIR/run"
export SCRIPTS_DIR="$PROJECT_DIR/scripts"
export LOG_DIR="$RUN_DIR/log"
export RAW_DIR="$OUTPUT_DIR/raw"
export PARQUET_DIR="$OUTPUT_DIR/parquet"
export MET_DIR="$DATA_DIR/ARL"
export GRIB_DIR="$DATA_DIR/GRIB"
export HYSPLIT="$PROJECT_DIR/bin/hysplit"
export CFG="$PROJECT_DIR/config.json"
export DUCKDB_BIN="$PROJECT_DIR/bin/duckdb"

export START_DATE=$(jq -r '.date_start' "$CFG")
export END_DATE=$(jq -r '.date_end' "$CFG")
export DURATION=$(jq -r '.duration' "$CFG")

export T_START=$(date -u -d "$START_DATE" +%s)
export T_END=$(date -u -d "$END_DATE" +%s)

if [[ $T_START -gt $T_END ]]; then
  export DIRECTION=-1
  export SIM_LOWER=$T_END
  export SIM_UPPER=$T_START
else
  export DIRECTION=1
  export SIM_LOWER=$T_START
  export SIM_UPPER=$T_END
fi

export NOTIFY=true
if [ "$NOTIFY" = true ]; then
  if [ ! -f "$PROJECT_DIR/.env" ]; then
    echo "[ERROR] .env file not found in $PROJECT_DIR"
    exit 1
  fi

  export TOKEN=$(sed -n 's/^TOKEN=//p' "$PROJECT_DIR/.env" | tr -d '\"')
  export CHAT_ID=$(sed -n 's/^CHAT_ID=//p' "$PROJECT_DIR/.env" | tr -d '\"')
  
  if [[ -z "$TOKEN" || -z "$CHAT_ID" ]]; then
    echo "[ERROR] The TOKEN or CHAT ID variables are not defined in the .env file"
    exit 1
  fi
fi

notify() {
  local MSG
  printf -v MSG "$@"
  if [ "$NOTIFY" = true ] && [ -n "$TOKEN" ]; then
    local CLEAN_MSG=$(echo -n "$MSG" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')
    curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
         -d "chat_id=$CHAT_ID" -d "disable_notification=true" \
         --data-urlencode "text=$CLEAN_MSG" > /dev/null &
  fi
  printf "%s" "$MSG"
}
export -f notify