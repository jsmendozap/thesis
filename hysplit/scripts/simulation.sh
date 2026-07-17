#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/config.sh"
readonly CURRENT_TS="$1"

TIME="$(date -u -d "@$CURRENT_TS" +'%Y_%m_%d_%H')"
PARQUET_OUT="$PARQUET_DIR/traj_${TIME}.parquet"
RAW_TXT="$RAW_DIR/traj_${TIME}.txt"

if [ -f "$RAW_TXT" ] || [ -f "$PARQUET_OUT" ]; then
  printf "[SKIP] Output already exists for %s. Skipping.\n" "$TIME"
  exit 0
fi

END_SEC=$(( CURRENT_TS + (DIRECTION * DURATION * 3600) ))

if [[ $CURRENT_TS -lt $END_SEC ]]; then
  SIM_START=$CURRENT_TS
  SIM_END=$END_SEC
else
  SIM_START=$END_SEC
  SIM_END=$CURRENT_TS
fi

REQUIRED_FILES=$(python3 -c "
import sys, json
from datetime import datetime, timezone

start_date = datetime.fromtimestamp(int(sys.argv[1]), timezone.utc).date()
end_date = datetime.fromtimestamp(int(sys.argv[2]), timezone.utc).date()
periods = sys.argv[3].strip().split('\n')

required = []
for line in periods:
  if not line: continue
  parts = line.split('|')
  y, m, c, nc = int(parts[0]), int(parts[1]), parts[2], parts[3]
  days = json.loads(parts[4])
  
  for d in days:
    chunk_date = datetime(y, m, int(d)).date()
    if start_date <= chunk_date <= end_date:
      required.append(f'MET_{y}_{m:02d}_{c}_{nc}.ARL')
      break 

print('\n'.join(required))
" "$SIM_START" "$SIM_END" "$PERIODS")

MET_FILES=()
for file in $REQUIRED_FILES; do
  if [[ ! -f "$MET_DIR/$file" ]]; then
    printf "[INFO] Missing meteorology: %s. Postponing simulation %s\n" "$file" "$TIME" >&2
    exit 0
  fi
  MET_FILES+=("$file")
done

NUM_MET=${#MET_FILES[@]}

printf "traj_${TIME}\n" > "$STATUS_DIR/hysplit_sim.status" 2>/dev/null || true
TEMP_OUT_DIR="${OUTPUT_DIR}/out_${TIME}"
TEMP_RAW_TXT="$TEMP_OUT_DIR/traj_${TIME}.txt"
mkdir -p "$TEMP_OUT_DIR"
cd "$TEMP_OUT_DIR"

HYSPLIT_CLONE="$TEMP_OUT_DIR/hysplit_env"
cp -rs "$HYSPLIT" "$HYSPLIT_CLONE"

CONTROL_SRC="$HYSPLIT_CLONE/exec/CONTROL"
rm -f "$CONTROL_SRC"

{
  echo "$(date -u -d "@$CURRENT_TS" +'%y %m %d %H')"
  echo "$NUM_POINTS"
  echo "$POINTS"
  echo "$(( $DIRECTION * $DURATION ))"
  echo "$VERT_METHOD"
  echo "$TOP_MODEL"
  echo "$NUM_MET"
  
  for f in "${MET_FILES[@]}"; do
    echo "$MET_DIR/"
    echo "$f"
  done

  echo "./"
  echo "traj_${TIME}.txt"
} > "$CONTROL_SRC"

printf "[INFO] Executing HYSPLIT for %s\nUsing files: %s\n\n" "$(date -u -d "@$CURRENT_TS" +'%Y-%m-%d %H:%M:%S')" "${MET_FILES[*]}"

cd "$HYSPLIT_CLONE/exec"
if ./hyts_std > "output.log" 2>&1; then
  mv "output.log" "$LOG_DIR/output_${TIME}.log"
else
  printf "[ERROR] HYSPLIT failed for %s. Check log at %s/output.log\n" "$TIME" "$TEMP_OUT_DIR" >&2
  mv "output.log" "$LOG_DIR/output_${TIME}.log"
fi

cd "$PROJECT_DIR"
mv "$HYSPLIT_CLONE/exec/traj_${TIME}.txt" "$TEMP_RAW_TXT"

if [ -s "$TEMP_RAW_TXT" ]; then
  printf "[INFO] Converting traj_${TIME}.txt to Parquet...\n"

  awk '/PRESSURE/{flag=1; next} flag {$1=$1; print}' "$TEMP_RAW_TXT" | \
  "$DUCKDB_BIN" -c "COPY (
    SELECT * FROM read_csv('/dev/stdin', header=False, sep=' ', columns={
      'traj_id':'INT', 'met_file':'VARCHAR', 'year':'INT', 'month':'INT', 
      'day':'INT', 'hour':'INT', 'minute':'INT', 'forecast_hour':'INT', 
      'age':'DOUBLE', 'lat':'DOUBLE', 'long':'DOUBLE', 'height':'DOUBLE', 
      'pressure':'DOUBLE', 'rain':'DOUBLE', 'blh':'DOUBLE', 'rh':'DOUBLE', 
      'sphu':'DOUBLE'
    })
  ) TO '$PARQUET_OUT' (FORMAT PARQUET, COMPRESSION 'ZSTD');"

  if [ -f "$PARQUET_OUT" ]; then
    mv "$TEMP_RAW_TXT" "$RAW_DIR"
    cd "$OUTPUT_DIR" && rm -rf "$TEMP_OUT_DIR"
    printf "[OK] Simulation ${TIME} complete and converted to Parquet.\n"
  else
    printf "[ERROR] Parquet file could not be generated from txt file: ${TIME}.\n"
    exit 1
  fi
else
  printf "[ERROR] No output file generated for ${TIME}. Please check the log.\n"
  exit 1
fi
