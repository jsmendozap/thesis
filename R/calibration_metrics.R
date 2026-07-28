pacman::p_load(arrow, tidyverse, duckspatial)

calibration_metrics <- function(dataset, mask){

  con <- ddbs_create_conn(threads = 4, memory_limit_gb = 5)
  worker_tmp <- tempfile(pattern = "duckdb_", tmpdir  = here("temp"))
  
  on.exit({
    dbDisconnect(con, shutdown = TRUE)
    unlink(worker_tmp, recursive = TRUE)
  }, add = TRUE)

  dbExecute(con, sprintf("SET temp_directory='%s';", worker_tmp))

  duckdb_register(con, "mask_grid", mask)

  simulation_year <- str_match(dataset, "year=(\\d{4})")[, 2]
  simulation_month <- str_match(dataset, "month=([a-z]+)/")[, 2]
  simulation_duration <- str_match(dataset, "duration=(\\d{1,2})")[, 2]

  total_trajectories <- open_dataset(dataset, format = "parquet") %>%
    to_duckdb(con = con) %>%
    summarise(n = n_distinct(id, na.rm = TRUE)) %>%
    pull(n)

  location_contribution <- open_dataset(dataset, format = "parquet") %>% 
    to_duckdb(con = con, table_name = "traj_view") %>%
    mutate(
      lon = ST_X(geometry), 
      lat = ST_Y(geometry),
    ) %>%
    filter(
      lon >= -80, lon <= 20,
      lat >= -35, lat <= 30,
      !is.na(fraction)
    ) %>%
    mutate(
      lon_idx = as.integer(floor(lon * 4)),
      lat_idx = as.integer(floor(lat * 4))
    ) %>%
    inner_join(
      tbl(con, "mask_grid"), 
      by = c("lon_idx", "lat_idx")
    ) %>%
    group_by(location) %>%
    summarise(
      fraction = sum(fraction, na.rm = TRUE)/total_trajectories,
      points = n()
    ) %>%
    to_arrow() %>%
    mutate(year = simulation_year, month = simulation_month, duration = simulation_duration) %>%
    collect()

  d_tot <- open_dataset(dataset, format = "parquet") %>%
    to_duckdb(con = con) %>%
    group_by(id) %>%
    summarise(d_tot = 1 - sum(fraction, na.rm = TRUE), .groups = "drop") %>%
    summarise(unknown_origin = mean(d_tot, na.rm = TRUE), .groups = "drop") %>%
    mutate(year = simulation_year, month = simulation_month, duration = simulation_duration) %>%
    collect()

  location_contribution %>%
    inner_join(d_tot,  by = c("year", "month", "duration")) %>%
    pivot_wider(names_from = "location", values_from = c("fraction", "n")) %>%
    mutate(year = as.integer(year), duration = as.integer(duration)) %>%
    arrange(year, month, duration)

}
