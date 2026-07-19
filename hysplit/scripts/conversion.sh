#!/bin/bash
source "$(dirname "$0")/config.sh"

printf "Starting conversion task..\n"
exec 200>"$STATUS_DIR/conversion.lock"
flock -n 200 || { printf "Execution blocked by active instance\n"; exit 1; }

if [ ! -f "$RUN_DIR/era52arl.cfg" ]; then
  python3 <<EOF
import sys
import json
sys.path.append("$PROJECT_DIR/bin")
import era5utils

with open("$CFG") as f: 
  config = json.load(f)

sname = era5utils.getvars()
var3d = {v[4]: k for k,v in sname.items() if len(v) >= 4 and v[4] and k != 'SHGT'}
var2d = {v[4]: k for k,v in sname.items() if len(v) >= 4 and v[4] and k != 'HGTS'}

pl_vars = config.get("datasets").get("pressure").get("variables")
param3d = [var3d[x] for x in pl_vars if x in var3d]

sfc_vars = config.get("datasets").get("surface").get("variables")
param2d = [var2d[x] for x in sfc_vars if x in var2d]

levtype = "pl"
levs = [int(x) for x in config.get("datasets").get("pressure").get("pressure_levels")]

print(f"[INFO] 3D params: {param3d}")
print(f"[INFO] 2D params: {param2d}")
print(f"[INFO] Levels: {levs}")

era5utils.write_cfg(param3d, param2d, levs, tm=1, levtype=levtype, cfgname="era52arl.cfg")
EOF
fi

if [ -f "$PROJECT_DIR/era52arl.cfg" ]; then
  mv "$PROJECT_DIR/era52arl.cfg" "$RUN_DIR/era52arl.cfg"
  printf "[OK] era52arl.cfg saved in $RUN_DIR \n"
fi

if [ ! -f "$RUN_DIR/era52arl.cfg" ]; then
  printf "[ERROR] era52arl.cfg not found in $RUN_DIR"
  exit 1
fi

FILES=( $(ls $GRIB_DIR | grep -i \.grib$ | cut -d'_' -f2- | sort -u | sed 's/\.grib$//I') )

if [ ${#FILES[@]} -eq 0 ]; then
    printf "[ERROR] No GRIB files found in $GRIB_DIR \n"
    exit 1
fi

printf "\n--- Starting conversion of GRIB files to ARL---\n"

for file in "${FILES[@]}"; do
  IFS='_' read -r year month chunk n_chunks <<< "$file"
  printf "[INFO] Processing year: $year, month: $month, chunk: $chunk/$n_chunks\n"

  PRES_FILE="PRES_${year}_${month}_${chunk}_${n_chunks}.GRIB"
  SURF_FILE="SFC_${year}_${month}_${chunk}_${n_chunks}.GRIB"
  OUT_FILE="MET_${year}_${month}_${chunk}_${n_chunks}.ARL"

  if [ -f "$MET_DIR/$OUT_FILE" ]; then
    printf "[INFO] $OUT_FILE already exists, skipping conversion\n"
    continue
  fi
  
  if [[ ! -f "$GRIB_DIR/$PRES_FILE" || ! -f "$GRIB_DIR/$SURF_FILE" ]]; then
    printf "[ERROR] Missing files for %s. Check %s or %s\n" "$file" "$PRES_FILE" "$SURF_FILE"
    continue
  fi

  printf "$OUT_FILE\n" > "$STATUS_DIR/hysplit_conv.status"
  cd "$RUN_DIR"
  LD_LIBRARY_PATH="$PROJECT_DIR/deps/eccodes/lib:$LD_LIBRARY_PATH" ./era52arl -v \
    -i"$GRIB_DIR/$PRES_FILE" \
    -a"$GRIB_DIR/$SURF_FILE" \
    -o"$MET_DIR/$OUT_FILE.tmp"
      
  if [ $? -eq 0 ]; then
    mv "$MET_DIR/$OUT_FILE.tmp" "$MET_DIR/$OUT_FILE"
    printf "[OK] ARL file successfully created: $OUT_FILE\n"

    printf "[INFO] Triggering execution checker in background...\n"
    "$SCRIPTS_DIR/execution.sh" >> "$LOG_DIR/execution_bg.log" 2>&1 200>&- &
  fi
done
