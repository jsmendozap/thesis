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
  year=$(echo "$TIME" | cut -d'_' -f1)
  month=$(echo "$TIME" | cut -d'_' -f2)

  mkdir -p "$OUTPUT_DIR/year=$year/month=$month"
  "$DUCKDB_BIN" << EOF
SET threads TO 1; 

COPY (
  WITH raw_data AS (
    SELECT 
      row_number() OVER () AS line_id,
      regexp_replace(trim(column0), '\s+', ' ', 'g') AS raw_line
    FROM read_csv(
      '$TEMP_RAW_TXT',
      header = FALSE,
      all_varchar = TRUE,
      delim = chr(0),
      quote = '',
      escape = ''
    )
    WHERE trim(column0) != ''
  )
  SELECT 
    line_id,
    raw_line,
    CASE 
      WHEN line_id > (SELECT MAX(line_id) FROM raw_data WHERE raw_line LIKE '%PRESSURE%') 
        THEN replace('$TIME', '_', '') || lpad(split_part(raw_line, ' ', 1), 4, '0')
      
      WHEN length(string_split(raw_line, ' ')) = 7 
        THEN replace('$TIME', '_', '') || lpad(CAST(row_number() OVER (PARTITION BY length(string_split(raw_line, ' ')) = 7 ORDER BY line_id) AS VARCHAR), 4, '0')
      
      ELSE NULL 
    END AS id
  FROM raw_data
) TO '$OUTPUT_DIR/year=$year/month=$month/traj_${TIME}.parquet' 
(FORMAT PARQUET, COMPRESSION ZSTD, OVERWRITE_OR_IGNORE 1);
EOF

  if [ $? -eq 0 ]; then
    rm -r "$TEMP_OUT_DIR"
  else
    printf "[ERROR] DuckDB conversion failed for ${TIME}.\n"
    exit 1
  fi

else
  printf "[ERROR] No output file generated for ${TIME}. Please check the log.\n"
  exit 1
fi
