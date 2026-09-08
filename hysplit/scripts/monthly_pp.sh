#!/bin/bash
mkdir -p /eiche2/JUAN/thesis/temp/temp_monthly

for f in /eiche2/JUAN/simulation/data/GRIB/SFC_*; do

  printf "Processing file: %s\n" "$f"
  cdo -b F32 -f nc4 \
      -setname,precipitation \
      -mulc,1000 \
      -monsum \
      -sellonlatbox,-77.7,-66.8,-4.3,3.1 \
      -selname,tp,var228 \
      "$f" "/eiche2/JUAN/thesis/temp/temp_monthly/$(basename "$f" | cut -f 1 -d '.').nc"
done

cdo mergetime /eiche2/JUAN/thesis/temp/temp_monthly/*.nc /eiche2/JUAN/thesis/data/precipitation_mm.nc

rm -rf /eiche2/JUAN/thesis/temp/temp_monthly