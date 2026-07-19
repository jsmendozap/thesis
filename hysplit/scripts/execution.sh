#!/bin/bash
source "$(dirname "$0")/config.sh"

printf "Starting HYSPLIT parallel execution..\n"
exec 201> "$STATUS_DIR/execution.lock"
flock -n 201 || { printf "Execution blocked by active instance.\n"; exit 0; }

printf "[OK] Preparing HYSPLIT environment...\n"

export POINTS=$(jq -r '.control.points[] | "\(.lat) \(.lon) \(.height)"' "$CFG")
export NUM_POINTS=$(echo "$POINTS" | wc -l)
export VERT_METHOD=$(jq -r '.control.vertical_method' "$CFG")
export TOP_MODEL=$(jq -r '.control.top_model' "$CFG")

TCL_SRC="$PROJECT_DIR/bin/hysplit/guicode/traj_cfg.tcl"
OUTPUT_CFG="$RUN_DIR/SETUP.CFG"
ACTIVE_VARS=" $(jq -r 'try(.output | join(" ")) catch empty' "$CFG") "

if [ ! -f "$OUTPUT_CFG" ]; then
  declare -A SETUP_VARS

  while read -r k v; do
    if [[ -n "$k" ]]; then
      SETUP_VARS["$k"]="$v"
    fi
  done < <(jq -r 'try(.setup | to_entries[] | "\(.key) \(.value)") catch empty' "$CFG")

  if [[ -n $ACTIVE_VARS || ${#SETUP_VARS[@]} -gt 0 ]]; then
    {
      echo "&SETUP"
      sed -n '/proc reset_config/,/}/p' "$TCL_SRC" | grep "^set" | while read -r _ key val; do
      
        if [[ $key =~ ^(tset|delt)$ ]]; then
          continue
        fi

        if [[ $ACTIVE_VARS == *" $key "* ]]; then
          val=1
        fi 

        if [[ -n ${SETUP_VARS[$key]} ]]; then
          val=${SETUP_VARS[$key]}
        fi
        
        echo $key = $val,
      done
      
      echo "/"
    } > "$OUTPUT_CFG"
    cp "$OUTPUT_CFG" "$HYSPLIT/exec/"
  fi
fi

MAX_JOBS=8
for (( current=SIM_LOWER; current<=SIM_UPPER; current+=(TR_INTERVAL * 3600) )); do
  TIME="$(date -u -d "@$current" +'%Y_%m_%d_%H')"
  if [ ! -f "$PARQUET_DIR/traj_${TIME}.parquet" ]; then
    echo "$current"
  fi
done | xargs -I {} -P "$MAX_JOBS" bash -c 'exec "$0" "$@" 201>&-' "$SCRIPTS_DIR/simulation.sh" "{}"
