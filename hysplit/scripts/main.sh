#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/config.sh"

printf "[INFO] Starting main process\n"
trap 'printf "\n[ABORT] Killing process tree...\n"; trap "" SIGTERM; kill -TERM -$$ 2>/dev/null; rm -f "$STATUS_DIR"/hysplit_*.status "$STATUS_DIR"/*.lock; exit 1' SIGINT SIGTERM

NOTIFY=true
if [ "$NOTIFY" = true ]; then
  if [ ! -f "$PROJECT_DIR/.env" ]; then
    echo "[ERROR] .env file not found in $PROJECT_DIR"
    exit 1
  fi

  TOKEN=$(sed -n 's/^TOKEN=//p' "$PROJECT_DIR/.env" | tr -d '\"')
  CHAT_ID=$(sed -n 's/^CHAT_ID=//p' "$PROJECT_DIR/.env" | tr -d '\"')
  
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

TOTAL_SIMS=$(( (SIM_UPPER - SIM_LOWER) / (TR_INTERVAL * 3600) + 1 ))
LAST_HEARTBEAT=$(date +%s)
HEARTBEAT_INTERVAL=900

rm -f "$STATUS_DIR"/hysplit_*.status "$STATUS_DIR"/*.lock 

"$SCRIPTS_DIR/download.sh" > "$LOG_DIR/download.log" 2>&1 &

send_update() {
    local DL_STAT CV_STAT SM_STAT 
    local EXP_GRIBS EXP_ARLS EXP_SIMS
    local ACT_GRIBS ACT_ARLS ACT_SIMS
    local P_GRIB P_ARL P_SIM

    DL_STAT=$(cat "$STATUS_DIR"/hysplit_dl.status 2>/dev/null || echo "Inactive")
    CV_STAT=$(cat "$STATUS_DIR"/hysplit_conv.status 2>/dev/null || echo "Inactive")
    SM_STAT=$(cat "$STATUS_DIR"/hysplit_sim.status 2>/dev/null || echo "Inactive")
    
    EXP_ARLS=$(wc -l <<< "$PERIODS")
    EXP_GRIBS=$(( EXP_ARLS * 2 ))
    EXP_SIMS=$TOTAL_SIMS

    ACT_GRIBS=$(find "$GRIB_DIR" -maxdepth 1 -name "*.GRIB" 2>/dev/null | wc -l)
    ACT_ARLS=$(find "$MET_DIR" -maxdepth 1 -name "*.ARL" 2>/dev/null | wc -l)
    ACT_SIMS=$(find "$PARQUET_DIR" -maxdepth 1 -name "*.parquet" 2>/dev/null | wc -l)

    P_GRIB=$(( EXP_GRIBS > 0 ? (ACT_GRIBS * 100) / EXP_GRIBS : 0 ))
    P_ARL=$(( EXP_ARLS > 0 ? (ACT_ARLS * 100) / EXP_ARLS : 0 ))
    P_SIM=$(( EXP_SIMS > 0 ? (ACT_SIMS * 100) / EXP_SIMS : 0 ))

    notify "[PROJECT UPDATE]\n\nDOWNLOADS\nCurrent: %d\nExpected: %d\nProgress: %d%%\nState: %s\n\nCONVERSION\nCurrent: %d\nExpected: %d\nProgress: %d%%\nState: %s\n\nTRAJECTORIES\nCurrent: %d\nExpected: %d\nProgress: %d%%\nState: %s\n" \
    "$ACT_GRIBS" "$EXP_GRIBS" "$P_GRIB" "$DL_STAT" \
    "$ACT_ARLS" "$EXP_ARLS" "$P_ARL" "$CV_STAT" \
    "$ACT_SIMS" "$EXP_SIMS" "$P_SIM" "$SM_STAT"
}

send_update

while true; do
    N_PARQUETS=$(find "$PARQUET_DIR" -maxdepth 1 -name "*.parquet" 2>/dev/null | wc -l)

    if (( N_PARQUETS >= TOTAL_SIMS )); then
        notify "[OK] Pipeline ended. %d trajectories generated.\n" "$N_PARQUETS"
        rm -f "$STATUS_DIR"/hysplit_*.status "$STATUS_DIR"/*.lock
        exit 0
    fi

    CURRENT_TIME=$(date +%s)
    if (( CURRENT_TIME - LAST_HEARTBEAT >= HEARTBEAT_INTERVAL )); then
        send_update
        LAST_HEARTBEAT=$CURRENT_TIME
    fi

    sleep 60
done