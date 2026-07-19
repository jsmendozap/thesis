#!/bin/bash
source "$(dirname "$0")/config.sh"

printf "[INFO] Simulation window: %s to %s\n" "$(date -u -d "@$SIM_LOWER" +'%Y-%m-%d %H:%M:%S')" "$(date -u -d "@$SIM_UPPER" +'%Y-%m-%d %H:%M:%S')"
printf "[INFO] Data window required: %s to %s\n" "$MET_START_DATE" "$MET_END_DATE"

if [ -f "$PROJECT_DIR/.env" ]; then
    KEY=$(sed -n 's/^KEY=//p' "$PROJECT_DIR/.env" | tr -d '\"')
fi
  
if [ -z "$KEY" ]; then
    printf "[ERROR] The KEY variable is not defined in the .env file"
    exit 1
fi

BASE_URL="https://cds.climate.copernicus.eu/api/retrieve/v1"
DATASETS=$(jq -r '.datasets | keys[]' "$CFG")
HOURS=$(seq -f "%02g:00" 0 23 | jq -R . | jq -s -c .)
AREA=$(jq -c '.area' "$CFG")

echo "$PERIODS" | while IFS='|' read -r YEAR MONTH CHUNK N_CHUNKS DAYS; do
    printf "[INFO] Processing period: $YEAR-$MONTH (part ${CHUNK}/${N_CHUNKS})\n"

    for key in $DATASETS; do
        PRODUCT=$(jq -r ".datasets.$key.name" "$CFG")
        SUFFIX=$([[ "$key" == "pressure" ]] && echo "PRES" || echo "SFC")
        OUTFILE="${SUFFIX}_${YEAR}_${MONTH}_${CHUNK}_${N_CHUNKS}.GRIB"
        
        if [ -f "$GRIB_DIR/$OUTFILE" ]; then
            printf "\n[INFO] File already exists, skipping download: $OUTFILE \n"
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

            printf "[%s] Status: %s\n" "$OUTFILE" "$STATUS" > "$STATUS_DIR/hysplit_dl.status"

            [ "$STATUS" = "successful" ] && break
            [ "$STATUS" = "failed" ]     && printf "[ERROR] Job $PRODUCT failed: $JOB_ID" && exit 1

            sleep 300
            printf "[%s] Status: %s\n" "$OUTFILE" "$STATUS"
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
            printf  "[OK] $OUTFILE downloaded successfully \n"
        fi
        
        curl -X 'DELETE' -s \
            -o /dev/null \
            "$BASE_URL/jobs/$JOB_ID?allow_unauthenticated=false" \
            -H 'accept: application/json' \
            -H "PRIVATE-TOKEN: $KEY"

        printf "[OK] $OUTFILE downloaded successfully\n"
    done
    
    printf "[INFO] [INFO] Triggering conversion script in background...\n"
    "$SCRIPTS_DIR/conversion.sh" >> "$LOG_DIR/conversion_bg.log" 2>&1 &
done