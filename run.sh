#!/bin/bash
# =============================================================================
# run.sh — Execution of HYSPLIT with ERA5 data
# Usage:
#   ./run.sh              → Only convert and run HYSPLIT (assumes PRES.GRIB and SFC.GRIB already exist in ./data)
#   ./run.sh --download   → Download ERA5, convert and run HYSPLIT
# =============================================================================

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$PROJECT_DIR/data"
OUTPUT_DIR="$PROJECT_DIR/output"
RUN_DIR="$PROJECT_DIR/run"
HYSPLIT_EXEC="$PROJECT_DIR/build/hysplit/exec"
CFG="$RUN_DIR/config.json"

DOWNLOAD=false
CONVERT=true

# --- Parse flags -------------------------------------------------------------
for arg in "$@"; do
  case $arg in
    --download) DOWNLOAD=true ;;
    --skip-conversion) CONVERT=false ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

# --- Load environment variables ----------------------------------------------
if [ -f "$PROJECT_DIR/.env" ]; then
  export $(grep -v '^#' "$PROJECT_DIR/.env" | xargs)
else
  echo "[ERROR] .env file not found in $PROJECT_DIR"
  exit 1
fi

if [ -z "$KEY" ]; then
  echo "[ERROR] The KEY variable is not defined in the .env file"
  exit 1
fi

# --- 1. Download ERA5 data --------------------------------------------
if [ "$DOWNLOAD" = true ]; then
  printf "\n--- Downloading ERA5 data ---\n"

  BASE_URL="https://cds.climate.copernicus.eu/api/retrieve/v1"
  DATASETS=$(jq '.datasets | keys[]' "$CFG")
  AREA=$(jq -c '.area' "$CFG")

  START_DATE=$(jq -r '.date_start' "$CFG")
  END_DATE=$(jq -r '.date_end' "$CFG")
  
  PERIODS=$(python3 <<EOF
import json
from datetime import datetime, timedelta
import calendar

with open("$CFG") as f:
    config = json.load(f)

d1 = datetime.strptime("$START_DATE", '%Y-%m-%d %H:%M:%S')
d2 = datetime.strptime("$END_DATE", '%Y-%m-%d %H:%M:%S')
start, end = min(d1, d2), max(d1, d2)

curr = start
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
  print(f"{y}|{m:02d}|{json.dumps(days)}")
  
  if m == 12:
    curr = datetime(y + 1, 1, 1)
  else:
    curr = datetime(y, m + 1, 1)
EOF
)
  
  HOURS=$(seq -f "%02g:00" 0 23 | jq -R . | jq -s -c .)

  echo "$PERIODS" | while IFS='|' read -r YEAR MONTH DAYS; do
    printf "\n--- Processing period: $YEAR-$MONTH ---\n"
    
    for key in $DATASETS; do
      PRODUCT=$(jq -r ".datasets.$key.name" "$CFG")
      OUTFILE=$(jq -j -r \
                  --arg k "$key" \
                  --arg suffix "_${YEAR}_${MONTH}.GRIB" \
                  '.datasets[$k].output, $suffix' "$CFG")

      REQUEST=$(jq -c \
        --argjson area "$AREA" \
        --argjson days "$DAYS" \
        --argjson hours "$HOURS" \
        --argjson yr "$YEAR" \
        --argjson mo "$MONTH" \
        --argjson key "$key" \
        '.datasets[$key] | {
          product_type: "reanalysis",
          variable: .variables,
          year: $yr,
          month: $mo,
          day: $days,
          time: $hours,
          data_format: "grib",
          download_format: "unarchived",
          area: $area
        } + (if .pressure_levels then { "pressure_level": .pressure_levels } else {} end)' "$CFG")

      BODY=$(jq -n --argjson req "$REQUEST" '{"inputs": $req}')
      JOB_ID=$(curl -s -X POST \
          -H "PRIVATE-TOKEN: $KEY" \
          -H "Content-Type: application/json" \
          -d "$BODY" \
          "$BASE_URL/processes/$PRODUCT/execution" | jq -r '.jobID')

      while true; do
        STATUS=$(curl -s -X 'GET' \
        "$BASE_URL/jobs/$JOB_ID?qos=false&request=false&log=false&allow_unauthenticated=false" \
        -H "accept: application/json" \
        -H "PRIVATE-TOKEN: $KEY" | jq -r '.status')

        echo "  [$PRODUCT] Status: $STATUS"

        [ "$STATUS" = "successful" ] && break
        [ "$STATUS" = "failed" ]     && echo "[ERROR] Job $PRODUCT failed: $JOB_ID" && exit 1

        sleep 180 
      done

      DOWNLOAD_URL=$(curl -X 'GET' \
        "$BASE_URL/jobs/$JOB_ID/results?allow_unauthenticated=false" \
        -H "accept: application/json" \
        -H "PRIVATE-TOKEN: $KEY" \
        | jq -r '.asset.value.href')

      curl -L --progress-bar \
        -H "PRIVATE-TOKEN: $KEY" \
        -o "$DATA_DIR/$OUTFILE" \
        "$DOWNLOAD_URL"

      echo "[OK] $OUTFILE downloaded successfully"
    done
  done
fi

# --- 2. Write era52arl.cfg ------------------------------------------------
printf "\n--- Generating era52arl.cfg file ---\n"

if [ ! -f "$CFG" ]; then
  echo "[ERROR] Config file not found: $CFG"
  exit 1
fi

python3 <<EOF
import sys
import json
sys.path.append("$PROJECT_DIR/build")
import era5utils

with open("$CFG") as f: 
  config = json.load(f)

var = {v[4]: k for k,v in era5utils.getvars().items() if len(v) >= 4 and v[4]}

pl_vars = config.get("datasets").get("pressure").get("variables")
sfc_vars = config.get("datasets").get("surface").get("variables")

param3d = [var[x] for x in pl_vars if x in var]
param2d = [var[x] for x in sfc_vars if x in var]

levtype = "pl"
levs = [int(x) for x in config.get("datasets").get("pressure").get("pressure_levels")]

print(f"[INFO] 3D params: {param3d}")
print(f"[INFO] 2D params: {param2d}")
print(f"[INFO] Levels: {levs}")

era5utils.write_cfg(param3d, param2d, levs, tm=1, levtype=levtype, cfgname="era52arl.cfg")
EOF

if [ -f "$PROJECT_DIR/era52arl.cfg" ]; then
  mv "$PROJECT_DIR/era52arl.cfg" "$RUN_DIR/era52arl.cfg"
  echo "[OK] era52arl.cfg saved in $RUN_DIR"
else
  echo "[ERROR] Failed to write era52arl.cfg"
  exit 1
fi

if [ "$CONVERT" = true ]; then
# --- Verify GRIB files to ARL ----------------------------------------------
  FILES=$(ls $DATA_DIR | grep .GRIB | awk -F '[_.]' '{print $2"_"$3}' | sort -u)

  if [ -z "$FILES" ]; then
    echo "[ERROR] No GRIB files found in $DATA_DIR"
    exit 1
  fi

  # --- 3. Convert GRIB Files to ARL ----------------------------------------------------
  printf "\n--- Converting GRIB files to ARL---\n"

  cd "$PROJECT_DIR/run"
  for file in "$FILES"; do
    IFS='_' read -r year month <<< "$file"
    printf "\nProcessing year $year month $month \n"
    LD_LIBRARY_PATH="$PROJECT_DIR/deps/eccodes/lib:$LD_LIBRARY_PATH" \
    ./era52arl -v \
      -i"$DATA_DIR/PRES_${file}.GRIB" \
      -a"$DATA_DIR/SFC_${file}.GRIB" \
      -o"$OUTPUT_DIR/MET_${file}.ARL"

    printf "\n--- MET_${file}.ARL successfully saved in $OUTPUT_DIR---\n"
  done

  cd "$PROJECT_DIR"
fi

# --- 4. CONTROL ----------------------------------------------------------------
printf "\n--- Setting up CONTROL file ---\n"
CONTROL_SRC="$RUN_DIR/CONTROL"
CONTROL_DST="$HYSPLIT_EXEC/CONTROL"

if [ ! -f "$CONTROL_SRC" ]; then
  printf "\n--- ERROR: CONTROL file template not found in $CONTROL_SRC ---\n"
  exit 1
fi

ARL_FILES=($(ls "$OUTPUT_DIR" | grep "MET_.*\.ARL"))
NUM_MET=${#ARL_FILES[@]}

if [ $NUM_MET -eq 0 ]; then
  printf "\n--- ERROR: No ARL files found in $OUTPUT_DIR ---\n"
  exit 1
fi

printf "" > "$RUN_DIR/met_list.tmp"
for ARL in "${ARL_FILES[@]}"; do
  printf "${OUTPUT_DIR}/\n${ARL}\n" >> "$RUN_DIR/met_list.tmp"
done

sed -i "s|<<NUM_MET>>|$NUM_MET|g" "$CONTROL_SRC"
sed -i -e "/<<MET_BLOCK>>/r $RUN_DIR/met_list.tmp" -e "/<<MET_BLOCK>>/d" "$CONTROL_SRC"
sed -i '/^$/d' "$CONTROL_SRC"

rm "$RUN_DIR/met_list.tmp"
printf "\n--- CONTROL file configured successfully ---\n"

# --- 5. HYSPLIT ----------------------------------------------------------------
printf "\n--- Executing HYSPLIT ---\n"
cp "$RUN_DIR/SETUP.CFG" "$HYSPLIT_EXEC/"
cp "$CONTROL_SRC" "$CONTROL_DST"

cd "$HYSPLIT_EXEC" && ./hyts_std
printf "\n=== Simulation completed. Results saved in $OUTPUT_DIR ===\n"