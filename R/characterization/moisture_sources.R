pacman::p_load(DBI, duckdb, duckspatial, dplyr, dbplyr, arrow, here)

identify_sources <- function(trajectories, path, mask) {
  con <- ddbs_create_conn(threads = 4, memory_limit_gb = 5)
  worker_tmp <- tempfile(pattern = "duckdb_", tmpdir = here("temp"))

  on.exit(
    {
      dbDisconnect(con, shutdown = TRUE)
      unlink(worker_tmp, recursive = TRUE)
    },
    add = TRUE
  )

  duckdb_register(con, "mask_grid", mask)
  dbExecute(con, sprintf("SET temp_directory='%s';", worker_tmp))

  open_dataset(trajectories) %>%
    to_duckdb(con = con) %>%
    # Grouping by trajectory
    group_by(id) %>%
    # Section 2.1 - Moisture sources identification
    # Step 1: Removing trajectories without precipitation at t = 0
    mutate(
      pp_at_age_0 = ifelse(age == 0 & rain != 0, 1, 0) %>% max(na.rm = T)
    ) %>%
    filter(pp_at_age_0 == 1) %>%
    # Ensuring every trajectory will be ordered by age for upcoming compuations
    window_order(age) %>%
    mutate(
      # Step 2: Computing change in specific humidity in every timestep
      delta = sphu - lag(sphu),
      # Step 3 and 4: Evaporation sources are identified where the following conditions matches:
      # * Δq > Δqc = 0.2/6 h: Avoids possible false positives
      # * The height of the parcel is within the boundary layer. The 1.5 is a correction factor
      # When the parcel is located above the boundary layer the moisture source can't be attribuited
      # surface processes and therefore is labeled differently (e).
      # Average values of parcel's height and blh between [t, t - 1] are used to take into account
      # spatial and temporal variability in this measurements.

      # There are 3 possibles humidity sources according Sodemann:
      # * Surface evaporation
      # * Contributions from processes above the boundary layer
      # * Fraction of unknown origin (d_tot)
      # d_tot might be the result of:
      # * pre-existent humidity: At the beginning of the trajectory the air's parcel already contained a portion of moisture
      # In that case, the algorithm can't attribuite a evaporation source since it happened outside the temporal range.
      # * Sub-threshold increments: Any increase of humidity < Δqc is discarded under the assumpsion this is a numerical error.
      source = case_when(
        delta > 0.03 &
          (height + lag(height)) / 2 <= 1.5 * (blh + lag(blh)) / 2 ~ "bl",
        delta > 0.03 &
          (height + lag(height)) / 2 > 1.5 * (blh + lag(blh)) / 2 ~ "e",
        TRUE ~ NA
      ),
      # Step 5: When the conditions are fullfilled, a moisture source is identified and its position
      # is recorded as the mean point between [t, t - 1]
      lat = ifelse(!is.na(source), (lat + lag(lat)) / 2, NA),
      long = ifelse(!is.na(source), (long + lag(long)) / 2, NA),
      # Section 2.2 - Moisture source attribution
      # Fraction of humidity remaining after an intermediate precipitation event. Requires 2 conditions:
      # * delta < 0: There was a reduction in atmospheric humidity
      # * sphu > 0: Control condition, avoids zero division
      # If in any point of the trajectory exists an precipitation event or moisture reduction due to mixing with dry air,
      # sphu will decrease by a factor of sphu / lag(sphu). Otherwise, the humidity content remains equal (alpha = 1).
      alpha = ifelse(delta < 0 & lag(sphu) > 0, sphu / lag(sphu), 1) %>%
        coalesce(1)
    ) %>%
    # Accumulation starts from t = 0 until a given precipitation point in the trajectory
    window_order(desc(age)) %>%
    mutate(
      # The total percentage of moisture decrease along the whole trajectory is given by the cummulative
      # product of all the individuals fractions of remained humidity: f = ∏αi = exp(∑log(αi))
      survival_factor = ifelse(alpha <= 0, 1e-2, alpha) %>%
        log() %>%
        cumsum() %>%
        exp(),
      contribution = ifelse(!is.na(source), delta * survival_factor, 0),
      # Fractional contribution of every source is obtained by dividing by sphu at t = 0
      sphu_t0 = ifelse(age == 0, sphu, 0) %>% max(na.rm = T)
    ) %>%
    filter(sphu_t0 > 1e-6) %>%
    mutate(fraction = ifelse(contribution != 0, contribution / sphu_t0, 0)) %>%
    ungroup() %>%
    filter(!is.na(source)) %>%
    mutate(
      lon_idx = as.integer(floor(long * 4)),
      lat_idx = as.integer(floor(lat * 4))
    ) %>%
    select(
      id,
      age,
      source,
      contribution,
      fraction,
      long,
      lat,
      lon_idx,
      lat_idx
    ) %>%
    compute() %>%
    inner_join(
      tbl(con, "mask_grid"),
      by = c("lon_idx", "lat_idx")
    ) %>%
    mutate(
      geometry = ST_Point(long, lat),
      id = as.character(id)
    ) %>%
    select(id, age, source, contribution, fraction, location, geometry) %>%
    arrange(id) %>%
    to_arrow() %>%
    write_dataset(path = path, format = "parquet")

  return(path)
}
