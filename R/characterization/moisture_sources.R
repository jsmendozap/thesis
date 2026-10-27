pacman::p_load(DBI, duckdb, duckspatial, dplyr, dbplyr, arrow, here, terra)

identify_sources <- function(trajectories, qc, rh_arrival, rh_loss, rain_arrival,
                             path, pressure_data, mask, threads, memory) {
  
  con <- ddbs_create_conn(threads = threads, memory_limit_gb = memory)
  worker_tmp <- tempfile(pattern = "duckdb_", tmpdir = here("temp"))
  
  dbExecute(con, sprintf("SET temp_directory='%s';", worker_tmp))
  dbExecute(con, "SET preserve_insertion_order = false;")

  on.exit(
    {
      dbDisconnect(con, shutdown = TRUE)
      unlink(worker_tmp, recursive = TRUE)
      gc(full = T)
    },
    add = TRUE
  )
  
  rain_arrival_cond <- if (rain_arrival) quo(rain > 0) else quo(TRUE)
  mask_grid <- open_dataset(mask) %>% to_duckdb(con = con)

  sim_year  <- str_extract(trajectories, "(?<=year=)[0-9]{4}")
  sim_month <- str_extract(trajectories, "(?<=month=)[0-9]{2}")
  out.dir <- here(path, paste0("year=", sim_year), paste0("month=", sim_month))
  
  pressure <- rast(pressure_data) %>% tidyterra::select(starts_with("sp_")) / 100
  idx <- which(format(time(pressure), "%Y-%m") == paste0(sim_year, "-", sim_month))
  
  dataset <- open_dataset(trajectories) %>%
    to_duckdb(con = con) %>%
    mutate(parts = string_split(raw_line, " ")) %>%
    filter(length(parts) == 17) %>%
    transmute(
      id = id,
      age = parts[[9]],
      lat = parts[[10L]],
      lon = parts[[11]],
      height = parts[[12]],
      pressure = parts[[13]],
      rain = parts[[14]],
      blh = parts[[15]],
      rh = parts[[16]],
      sphu = parts[[17]]
    ) %>%
    mutate(across(2:10, ~ as.numeric(.x))) %>%
    filter(age %% 6 == 0)
  
  surface_pressure <- dataset %>%
    filter(age == 0) %>%
    distinct(lon, lat) %>%
    collect() %>%
    mutate(sp = terra::extract(pressure[[idx]], ., ID = FALSE)[[1]]) %>%
    copy_to(con, ., "surface_pressure", overwrite = TRUE)
  
  valid_trajectories <- dataset %>%
    group_by(id) %>%
    window_order(desc(age)) %>%
    mutate(
      dq_t0 = sphu - lead(sphu),
      prev_rh = lead(rh),
      pos_t0 = paste0(lat, "_", lon, "_", str_sub(id, end = 10))
    ) %>% 
    filter(age == 0) %>% 
    left_join(surface_pressure, by = join_by(lat, lon)) %>%
    ungroup() %>%
    group_by(pos_t0) %>% 
    window_order(desc(pressure)) %>%
    mutate(
      p_lower = coalesce((pressure + lag(pressure)) / 2, pmax(sp, pressure)),
      p_upper = coalesce((pressure + lead(pressure)) / 2, pressure),
      delta_p = (p_lower - p_upper) * 100,
      mass_kg = 30e3 * 30e3 * delta_p / 9.8
    ) %>% 
    filter(prev_rh > rh_arrival, dq_t0 < -qc, !!rain_arrival_cond) %>%
    ungroup() %>%
    mutate(
      dest_lon_idx = as.integer(floor(lon * 100)),
      dest_lat_idx = as.integer(floor(lat * 100))
    ) %>%
    inner_join(
      mask_grid %>% select(dest_hydrological_zone = hydrological_zone, lon_idx, lat_idx),
      by = c("dest_lon_idx" = "lon_idx", "dest_lat_idx" = "lat_idx")
    ) %>%
    select(
      id, dest_hydrological_zone, sphu_t0 = sphu, height_t0 = height,
      lon_t0 = lon, lat_t0 = lat, dq_t0, mass_kg
    )
  
  dataset%>%
    # --- Section 1: Moisture sources identification ---
    # Step 1: Removing trajectories without precipitation at t = 0
    inner_join(valid_trajectories, by = "id") %>%
    # Grouping by trajectory
    group_by(id) %>%
    # Sort chronologically (from past to present) to calculate step-by-step humidity changes
    window_order(age) %>%
    mutate(
      # Step 2: Computing change in specific humidity and relative humidity in every timestep
      delta = sphu - lag(sphu),
      # Step 3 and 4: Identify surface evaporation events.
      # Condition: Δq > Δqc = 0.3/6 h: Avoids possible false positives (numerical noise)
      # * The height of the parcel is within the boundary layer. The 1.5 is a correction factor.
      # When the parcel is located above the boundary layer the moisture source can't be attribuited
      # to surface processes and therefore is labeled differently (e).

      # There are 3 possibles humidity sources according Sodemann:
      # * Surface evaporation
      # * Contributions from processes above the boundary layer
      # * Fraction of unknown origin (d_tot)
      # d_tot might be the result of:
      # * pre-existent humidity: At the beginning of the trajectory the air's parcel already contained a portion of moisture
      # In that case, the algorithm can't attribuite a evaporation source since it happened outside the temporal range.
      # * Sub-threshold increments: Any increase of humidity < Δqc is discarded under the assumpsion this is a numerical error.
      is_source = coalesce(delta > qc, FALSE),
      blh_ratio = ifelse(is_source, height / blh, NA),
      
      # Step 5: When the conditions are fullfilled, a moisture source is identified and its position
      # is recorded as the mean point between [t, t - 1]
      source_lat = ifelse(is_source, (lat + lag(lat)) / 2, NA),
      source_lon = ifelse(is_source, (lon + lag(lon)) / 2, NA),
      
      # --- Section 2: Moisture source attribution ---
      
      # Fraction of remaining humidity after an intermediate precipitation event. Requires 2 conditions:
      # * delta < 0: There was a reduction in atmospheric humidity
      # * previous RH > 80
      # * sphu > 0: Control condition, avoids zero division
      # If in any point of the trajectory exists an precipitation event or moisture reduction due to mixing with dry air,
      # sphu will decrease by a factor of sphu / lag(sphu). Otherwise, the humidity content remains equal (alpha = 1).
      is_loss = coalesce(delta < -qc & lag(rh) > rh_loss, FALSE),
      alpha = ifelse(is_loss & lag(sphu) > 0, sphu / lag(sphu), 1) %>% coalesce(1)) %>%
    # Reverse the timeline. Order from arrival (t=0) backwards into the past.
    # This allows tracking how much of an old evaporation event survived all subsequent rainfalls.
    window_order(desc(age)) %>%
    mutate(
      # The total percentage of moisture decrease along the whole trajectory is given by the cummulative
      # product of all the individuals fractions of remaining humidity: f = ∏αi = exp(∑log(αi))
      # Represents the exact percentage of water that survived from the evaporation moment until t=0.
      survival_factor = ifelse(alpha <= 0, 1e-2, alpha) %>% log() %>% cumsum() %>% exp(),
      # Absolute water mass from each source that reached the target area
      contribution = ifelse(is_source, delta * survival_factor, 0)
    ) %>%
    # Drop empty parcels to avoid division by zero
    filter(sphu_t0 > 1e-6) %>%
    # Relative contribution of each source (0 to 1)
    # Fractional contribution: Percentaje of contribution of the source i to the moisture at t = 0 
    mutate(
      fractional_contribution = ifelse(contribution != 0, contribution / sphu_t0, 0),
      water_mass_kg = fractional_contribution * mass_kg * abs(dq_t0) / 1000
    ) %>%
    ungroup() %>%
    filter(is_source | age == 0) %>%
    mutate(precipitation_kg = ifelse(age == 0, mass_kg * abs(dq_t0) / 1000, 0)) %>%
    # --- Section 3: Spatial Indexing and Mask Join ---

    # Convert continuous coordinates into discrete 0.01-degree grid cells.
    # Multiplying by 100 (1 / 0.01 = 100) and rounding down (floor) assigns every point
    # to a unique integer ID representing its grid box.
    mutate(
      source_lon_idx = as.integer(floor(source_lon * 100)),
      source_lat_idx = as.integer(floor(source_lat * 100))
    ) %>%
    select(
      id,
      age,
      fractional_contribution,
      water_mass_kg,
      precipitation_kg,
      dest_hydrological_zone,
      is_source,
      blh_ratio,
      source_lon,
      source_lat,
      source_lat_idx,
      source_lon_idx,
      height_t0, 
      lon_t0,
      lat_t0
    ) %>%
    # Match the points to the mask using the integer IDs instead of spatial distances.
    # Source humidity points
    left_join(
      mask_grid,
      by = c("source_lon_idx" = "lon_idx", "source_lat_idx" = "lat_idx")
    ) %>%
    mutate(
      is_ocean = ifelse(is_source, coalesce(is_ocean, TRUE), NA),
      country_or_ocean = ifelse(is_source, coalesce(country_or_ocean, "Unclassified Ocean"), NA),
      source_domain = ifelse(is_source, coalesce(source_domain, "Unclassified Ocean"), NA),
      is_aoi = ifelse(is_source, coalesce(is_aoi, FALSE), NA),
      id = as.character(id)
    ) %>%
    select(
      id,
      age,
      fractional_contribution,
      water_mass_kg,
      precipitation_kg,
      blh_ratio,
      country_or_ocean,
      ecoregion,
      is_aoi,
      is_ocean,
      source_hydrological_zone = hydrological_zone,
      dest_hydrological_zone,
      source_domain,
      height_t0,
      lat_t0, 
      lon_t0,
      source_lon,
      source_lat
    ) %>%
    to_arrow() %>%
    write_dataset(path = out.dir, format = "parquet")

  return(out.dir)
}
