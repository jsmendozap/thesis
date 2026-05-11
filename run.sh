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
KEY="176198c6-d6c0-4d84-9338-ed6434b06334"

DOWNLOAD=false

# --- Parse flags -------------------------------------------------------------
for arg in "$@"; do
  case $arg in
    --download) DOWNLOAD=true ;;
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
  DATES=$(current="$START_DATE"; while [ "$current" != "$(date -d "$END_DATE + 1 day" +%Y-%m-%d)" ]; do
      date -d "$current" +"%Y %m %d"
      current=$(date -d "$current + 1 day" +%Y-%m-%d)
  done)
  YEARS=$(echo "$DATES"  | cut -d' ' -f1 | sort -u | jq -R . | jq -s -c .)
  MONTHS=$(echo "$DATES" | cut -d' ' -f2 | sort -u | jq -R . | jq -s -c .)
  DAYS=$(echo "$DATES"   | cut -d' ' -f3 | sort -u | jq -R . | jq -s -c .)
  HOURS=$(seq -f "%02g:00" 0 23 | jq -R . | jq -s -c .)

  for key in $DATASETS; do
    PRODUCT=$(jq -r ".datasets.$key.name" "$CFG")
    OUTFILE=$(jq -r ".datasets.$key.output" "$CFG")

    REQUEST=$(jq -c \
      --argjson area "$AREA" \
      --argjson days "$DAYS" \
      --argjson hours "$HOURS" \
      --argjson yr "$YEARS" \
      --argjson mo "$MONTHS" \
      --argjson idx "$i" \
      '.datasets[$idx] | {
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

else
  printf "\n--- Skipping download ---\n"
fi

# --- Verify that the GRIB files exist ------------------------------------------
if [ ! -f "$DATA_DIR/PRES.GRIB" ] || [ ! -f "$DATA_DIR/SFC.GRIB" ]; then
  echo "[ERROR] GRIB files not found in $DATA_DIR"
  exit 1
fi

# --- 2. Write era52arl.cfg ------------------------------------------------
printf "\n--- Generating era52arl.cfg file ---\n"

if [ ! -f "$CFG" ]; then
  echo "[ERROR] Config file not found: $CFG"
  exit 1
fi

printf "\n--- Generating era52arl.cfg file ---\n"
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
  echo "[OK] era52arl.cfg written to $RUN_DIR/era52arl.cfg"
else
  echo "[ERROR] Failed to write era52arl.cfg"
  exit 1
fi

# --- 3. Execute era52arl ----------------------------------------------------
printf "\n--- Executing era52arl ---\n"
cd "$PROJECT_DIR/run"
LD_LIBRARY_PATH="$PROJECT_DIR/deps/eccodes/lib:$LD_LIBRARY_PATH" \
  ./era52arl -v \
    -i"$DATA_DIR/PRES.GRIB" \
    -a"$DATA_DIR/SFC.GRIB" \
    -o"$OUTPUT_DIR/MET.ARL"
cd "$PROJECT_DIR"
printf "\n--- ARL file successfully saved in $OUTPUT_DIR ---\n"

# --- 4. CONTROL ----------------------------------------------------------------
printf "\n--- Setting up CONTROL file ---\n"
CONTROL_SRC="$RUN_DIR/CONTROL"
CONTROL_DST="$HYSPLIT_EXEC/CONTROL"

if [ ! -f "$CONTROL_SRC" ]; then
  printf "\n--- ERROR: CONTROL file template not found in $CONTROL_SRC ---\n"
  exit 1
fi

sed -i "s|<<OUTPUT_DIR>>|$OUTPUT_DIR/|g" "$CONTROL_SRC"

# --- 5. HYSPLIT ----------------------------------------------------------------
printf "\n--- Executing HYSPLIT ---\n"
cp "$RUN_DIR/SETUP.CFG" "$HYSPLIT_EXEC/"
cp "$CONTROL_SRC" "$CONTROL_DST"

cd "$HYSPLIT_EXEC" && ./hyts_std
printf "\n=== Simulation completed. Results saved in $OUTPUT_DIR ===\n"

PROJECT_DIR=$(dirname "$0")
HYSPLIT_DIR="$PROJECT_DIR/build/hysplit"

cp "$PROJECT_DIR/run/CONTROL"   "$HYSPLIT_DIR/exec/"
cp "$PROJECT_DIR/run/SETUP.CFG" "$HYSPLIT_DIR/exec/"

cd "$HYSPLIT_DIR/exec" && ./hyts_std