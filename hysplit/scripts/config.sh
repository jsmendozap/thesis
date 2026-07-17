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
export STATUS_DIR="$PROJECT_DIR/status"


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


export START_DATE=$(jq -r '.date_start' "$CFG")
export END_DATE=$(jq -r '.date_end' "$CFG")
export DURATION=$(jq -r '.duration' "$CFG")
export TR_INTERVAL=$(jq -r '.interval_traj // 24' "$CFG")

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

if [[ $DIRECTION -eq -1 ]]; then
  MET_LOWER=$(( SIM_LOWER - (DURATION * 3600) ))
  MET_UPPER=$SIM_UPPER
else
  MET_LOWER=$SIM_LOWER
  MET_UPPER=$(( SIM_UPPER + (DURATION * 3600) ))
fi

MET_START_DATE=$(date -u -d "@$MET_LOWER" +'%Y-%m-%d %H:%M:%S')
MET_END_DATE=$(date -u -d "@$MET_UPPER" +'%Y-%m-%d %H:%M:%S')

export PERIODS=$(python3 <<EOF
from datetime import datetime, timedelta
import calendar
import json

start = datetime.strptime("$MET_START_DATE", '%Y-%m-%d %H:%M:%S')
end = datetime.strptime("$MET_END_DATE", '%Y-%m-%d %H:%M:%S')

curr = start
chunk_size = 11

while curr <= end:
  y, m = curr.year, curr.month
  if y == start.year and m == start.month:
    s_day = start.day
  else:
    s_day = 1
    
  if y == end.year and m == end.month:
    e_day = end.day
  else:
    e_day = calendar.monthrange(y, m)[1]
    
  days = [f"{d:02d}" for d in range(s_day, e_day + 1)]
  days = [days[i:i + chunk_size] for i in range(0, len(days), chunk_size)]
  
  for chunk in range(0, len(days)): 
    n_chunks = len(days)
    dates = days[chunk]
    print(f"{y}|{m:02d}|{chunk + 1}|{n_chunks}|{json.dumps(dates)}")

  if m == 12:
    curr = datetime(y + 1, 1, 1)
  else:
    curr = datetime(y, m + 1, 1)
EOF
)
