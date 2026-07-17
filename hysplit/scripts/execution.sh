#!/bin/bash
source "$(dirname "$0")/config.sh"

printf "Starting HYSPLIT parallel execution..\n"
exec 201> "$STATUS_DIR/execution.lock"
flock -n 201 || { printf "Execution blocked by active instance.\n"; exit 0; }

MET_REQ_START=$SIM_LOWER
MET_REQ_END=$SIM_UPPER

if [[ $DIRECTION -eq -1 ]]; then
  MET_REQ_START=$(( SIM_LOWER - (DURATION * 3600) ))
fi

Y_REQ_START=$(date -u -d "@$MET_REQ_START" +%Y)
M_REQ_START=$(( 10#$(date -u -d "@$MET_REQ_START" +%m) ))
Y_REQ_END=$(date -u -d "@$MET_REQ_END" +%Y)
M_REQ_END=$(( 10#$(date -u -d "@$MET_REQ_END" +%m) ))

MISSING_MET=false
Y_CUR=$Y_REQ_START
M_CUR=$M_REQ_START

while [[ $Y_CUR -lt $Y_REQ_END || ( $Y_CUR -eq $Y_REQ_END && $M_CUR -le $M_REQ_END ) ]]; do
  printf -v MM "%02d" $M_CUR
  
  shopt -s nullglob
  monthly=("$MET_DIR"/MET_${Y_CUR}_${MM}_*.ARL)
  shopt -u nullglob
  
  if [[ ${#monthly[@]} -eq 0 ]]; then
    printf "[INFO] Missing meteorology for %s-%s. Execution postponed.\n" "$Y_CUR" "$MM"
    MISSING_MET=true
    break 
  fi
  
  ((M_CUR++))
  if (( M_CUR > 12 )); then
    M_CUR=1
    ((Y_CUR++))
  fi
done

if [[ "$MISSING_MET" == true ]]; then
  exit 0
fi

printf "[OK] All required meteorology available. Preparing HYSPLIT environment...\n"

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

MAX_JOBS=4
for (( current=SIM_LOWER; current<=SIM_UPPER; current+=(TR_INTERVAL * 3600) )); do
  TIME="$(date -u -d "@$current" +'%Y_%m_%d_%H')"
  if [ ! -f "$PARQUET_DIR/traj_${TIME}.parquet" ]; then
    echo "$current"
  fi
done | xargs -I {} -P "$MAX_JOBS" sh -c 'exec "$0" "$@" 201>&-' "$SCRIPTS_DIR/simulation.sh" "{}"
