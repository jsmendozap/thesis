pacman::p_load(arrow, tidyverse, duckdb, duckspatial, DBI, here, zoo)

trajectory_duration <- function(dataset){

  worker_tmp <- tempfile(pattern = "duckdb_", tmpdir = here("temp"))
  con <- ddbs_create_conn(threads = 4, memory_limit_gb = 5)
  worker_tmp <- tempfile(pattern = "duckdb_", tmpdir  = here("temp"))
  
  on.exit({
    dbDisconnect(con, shutdown = TRUE)
    unlink(worker_tmp, recursive = TRUE)
  }, add = TRUE)
  
  dbExecute(con, sprintf("SET temp_directory='%s';", worker_tmp))
  
  cuts <- tibble(durations = seq(24, 360, 24))
  duckdb_register(con, "temporal_cuts", cuts)
  
  simulation_year <- str_match(dataset, "year=(\\d{4})")[, 2] %>% as.integer()
  simulation_month <- str_match(dataset, "month=([a-z]+)")[, 2] 

  base_tbl <- open_dataset(dataset, format = "parquet") %>% 
    to_duckdb(con = con)

  total_trajectories <- base_tbl %>%
    summarise(n = n_distinct(id, na.rm = TRUE)) %>%
    pull(n)

  base_tbl %>%
    cross_join(tbl(con, "temporal_cuts")) %>%
    filter(age >= -durations) %>%
    group_by(durations, location) %>%
    summarise(
      fraction = sum(fraction, na.rm = TRUE) / total_trajectories,
      puntos = n(),
      .groups = "drop"
    ) %>%
    collect() %>%
    pivot_wider(
      names_from = location, 
      values_from = c(fraction, puntos),
      values_fill = list(fraction = 0, puntos = 0) 
    ) %>%
    mutate(
      unknown_origin = 1 - (fraction_Land + fraction_Ocean),
      year = simulation_year, 
      month = simulation_month
    ) %>%
    rename_all(~str_to_lower(.x)) %>%
    arrange(year, month, durations)
}



trajectory_points <- function(dataset){
  con <- ddbs_create_conn(threads = 4, memory_limit_gb = 5)
  worker_tmp <- tempfile(pattern = "duckdb_", tmpdir  = here("temp"))
  
  on.exit({
    dbDisconnect(con, shutdown = TRUE)
    unlink(worker_tmp, recursive = TRUE)
  }, add = TRUE)
  
  dbExecute(con, sprintf("SET temp_directory='%s';", worker_tmp))

  raw_dir <- str_replace(dataset, "output", "data")

  traj_map <- open_dataset(raw_dir) %>%
    to_duckdb(con = con) %>%
    filter(age == 0) %>%
    select(id, height) %>%
    mutate(launch_id = str_sub(id, 1, 10)) %>%
    group_by(launch_id) %>%
    window_order(height) %>%
    mutate(level = dense_rank(height)) %>%
    ungroup() %>%
    select(id, launch_id, level) %>%
    collect() 

  processed_agg <- open_dataset(dataset) %>%
    to_duckdb(con = con) %>%
    select(id, location, fraction) %>%
    group_by(id, location) %>%
    summarise(fraction = sum(fraction, na.rm = TRUE), .groups = "drop") %>%
    collect() 

  grid <- expand_grid(size = seq(30, 3000, 30), iteration = 1:100)

  results <- map2_dfr(grid$size, grid$iteration, function(size, iteration) {

    sampled_ids <- traj_map %>%
      group_by(launch_id, level) %>%
      slice_sample(n = size / 30, replace = FALSE) %>%
      ungroup() %>%
      pull(id)
    
    processed_agg %>%
      filter(id %in% sampled_ids) %>%
      group_by(location) %>%
      summarise(raw_fraction = sum(fraction, na.rm = TRUE), .groups = "drop") %>%
      mutate(
        total_mass = sum(raw_fraction, na.rm = TRUE),
        relative_fraction = raw_fraction / total_mass,
        size = size,
        iteration = iteration,
        year = as.integer(str_match(dataset, "year=(\\d{4})")[, 2]),
        month = str_match(dataset, "month=([a-z]+)")[, 2]
      ) %>%
      select(year, month, location, relative_fraction, size, iteration)
  })
    
  results %>%
    filter(location == "Ocean") %>%
    group_by(year, month, size) %>%
    summarise(
      mean = mean(relative_fraction),
      sd = sd(relative_fraction),
      .groups = "drop"
    ) %>%
    mutate(
      cv = (sd / mean) * 100,
      month = factor(month, levels = c("march", "may", "july")),
      year = as.factor(year)
    )
}


simulation_parameters <- function(duration, points){
  max_duration <- duration %>%
    arrange(year, month, durations) %>% 
    group_by(year, month) %>%
    mutate(marginal_gain = lag(unknown_origin) - unknown_origin) %>%
    filter(marginal_gain < 0.01) %>%
    slice_head(n = 1) %>%
    ungroup() %>%
    pull(durations) %>%
    max()

  points_smooth <- points %>%
    group_by(year, month) %>%
    arrange(size, .by_group = TRUE) %>%
    mutate(
      delta = lag(cv) - cv,
      delta = rollmean(delta, k = 3, fill = NA, align = "right")
    ) %>%
    ungroup() %>%
    summarise(max_delta = max(delta, na.rm = TRUE), .by = size) %>%
    filter(!is.infinite(max_delta)) 

  max_trajectories <- points_smooth %>%
    arrange(desc(size), max_delta) %>%
    mutate(threshold = cummax(max_delta) > 0.25) %>%
    slice_tail(n = 1, by = threshold) %>%
    filter(threshold == F) %>%
    pull(size) %>%
    {plyr::round_any(./30, 10, ceiling) * 30}

  list(max_duration = max_duration, points_smooth =  points_smooth, max_trajectories = max_trajectories)

}
