#!/bin/bash
source "$(dirname "$0")/config.sh"

if [ -f "$PROJECT_DIR/.env" ]; then
    KEY=$(sed -n 's/^KEY=//p' "$PROJECT_DIR/.env" | tr -d '\"')
fi
  
if [ -z "$KEY" ]; then
    notify "[ERROR] The KEY variable is not defined in the .env file"
    exit 1
fi

BASE_URL="https://cds.climate.copernicus.eu/api/retrieve/v1"
DATASETS=$(jq -r '.datasets | keys[]' "$CFG")
HOURS=$(seq -f "%02g:00" 0 23 | jq -R . | jq -s -c .)
AREA=$(jq -c '.area' "$CFG")

if [[ $DIRECTION -eq -1 ]]; then
  MET_LOWER=$(( SIM_LOWER - (DURATION * 3600) ))
  MET_UPPER=$SIM_UPPER
else
  MET_LOWER=$SIM_LOWER
  MET_UPPER=$(( SIM_UPPER + (DURATION * 3600) ))
fi

MET_START_DATE=$(date -u -d "@$MET_LOWER" +'%Y-%m-%d %H:%M:%S')
MET_END_DATE=$(date -u -d "@$MET_UPPER" +'%Y-%m-%d %H:%M:%S')

notify "[INFO] Simulation window: %s to %s\n" "$(date -u -d "@$SIM_LOWER" +'%Y-%m-%d %H:%M:%S')" "$(date -u -d "@$SIM_UPPER" +'%Y-%m-%d %H:%M:%S')"
notify "[INFO] Data window required: %s to %s\n" "$MET_START_DATE" "$MET_END_DATE"

PERIODS=$(python3 <<EOF
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

echo "$PERIODS" | while IFS='|' read -r YEAR MONTH CHUNK N_CHUNKS DAYS; do
    notify "[INFO] Processing period: $YEAR-$MONTH (part ${CHUNK}/${N_CHUNKS})\n"

    for key in $DATASETS; do
        PRODUCT=$(jq -r ".datasets.$key.name" "$CFG")
        SUFFIX=$([[ "$key" == "pressure" ]] && echo "PRES" || echo "SFC")
        OUTFILE="${SUFFIX}_${YEAR}_${MONTH}_${CHUNK}_${N_CHUNKS}.GRIB"
        
        if [ -f "$GRIB_DIR/$OUTFILE" ]; then
            printf "\n[INFO] File already exists, skipping download: $OUTFILE"
            continue
        fi

        REQUEST=$(jq -c \
        --argjson area "$AREA" \
        --argjson days "$DAYS" \
        --argjson hours "$HOURS" \
        --arg yr "$YEAR" \
        --arg mo "$MONTH" \
        --arg key "$key" \
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

        printf "\n[INFO] Job submitted for $key: $YEAR-$MONTH\n"

        while true; do
            STATUS=$(curl -s -X 'GET' \
            "$BASE_URL/jobs/$JOB_ID?qos=false&request=false&log=false&allow_unauthenticated=false" \
            -H "accept: application/json" \
            -H "PRIVATE-TOKEN: $KEY" | jq -r '.status')

            printf "[%s] Status: %s\033[0K\n" "$PRODUCT" "$STATUS"

            [ "$STATUS" = "successful" ] && break
            [ "$STATUS" = "failed" ]     && notify "[ERROR] Job $PRODUCT failed: $JOB_ID" && exit 1

            secs=300
            while (( secs > 0 )); do
            printf "Retry download in %02d:%02d\033[0K\r" $((secs / 60)) $((secs % 60))
            sleep 1
            ((secs--))
            done
        done
        
        DOWNLOAD_URL=$(curl -X 'GET' \
            "$BASE_URL/jobs/$JOB_ID/results?allow_unauthenticated=false" \
            -H "accept: application/json" \
            -H "PRIVATE-TOKEN: $KEY" \
            | jq -r '.asset.value.href')

        printf "\n"

        curl -L --progress-bar -H "PRIVATE-TOKEN: $KEY" -o "$GRIB_DIR/$OUTFILE.tmp" "$DOWNLOAD_URL"
        
        if [ $? -eq 0 ]; then
            mv "$GRIB_DIR/$OUTFILE.tmp" "$GRIB_DIR/$OUTFILE"
            notify  "[OK] $OUTFILE downloaded successfully \n"
        fi
        
        curl -X 'DELETE' -s \
            -o /dev/null \
            "$BASE_URL/jobs/$JOB_ID?allow_unauthenticated=false" \
            -H 'accept: application/json' \
            -H "PRIVATE-TOKEN: $KEY"

        printf "[OK] $OUTFILE downloaded successfully\n"
    done
    
    printf "[INFO] Executing conversion script\n"
    "$SCRIPTS_DIR/conversion.sh" &
done