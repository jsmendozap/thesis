pacman::p_load(
  arrow,
  tidyverse,
  duckspatial,
  DBI,
  targets,
  dbplyr,
  here,
  sf,
  jsonlite
)

grid_convergence <- function(profile, moisture_sources, pp) {
  
  con <- ddbs_create_conn(threads = 12, memory_limit_gb = 70)
  dbExecute(con, "SET preserve_insertion_order = false;")
  worker_tmp <- tempfile(pattern = "duckdb_", tmpdir = here("temp"))
  
  on.exit({
    dbDisconnect(con, shutdown = TRUE)
    unlink(worker_tmp, recursive = TRUE)
    gc()
  }, add = TRUE)
  
  dbExecute(con, sprintf("SET temp_directory='%s';", worker_tmp))
  
  sim_year <- str_extract(moisture_sources, "(?<=year=)[0-9]{4}")
  sim_month <- str_extract(moisture_sources, "(?<=month=)[0-9]{2}")
  
  basin_pp <- open_dataset(pp) %>%
    filter(year == !!sim_year, month == !!sim_month) %>%
    collect()
  
  base_trajectories <- str_replace(moisture_sources, "output", "data") %>%
    open_dataset() %>%
    to_duckdb(con = con) %>%
    mutate(parts = string_split(raw_line, " ")) %>%
    filter(length(parts) == 7) %>%
    transmute(
      id, 
      height = as.numeric(parts[[7]]),
      launch_lon = as.numeric(parts[[6]]),
      launch_lat = as.numeric(parts[[5]])
    ) %>%
    compute(name = "base_trajectories")
  
  traj_catalog <- open_dataset(moisture_sources) %>%
    filter(!is.na(dest_hydrological_zone)) %>%
    select(id, dest_hydrological_zone) %>%
    distinct() %>%
    to_duckdb(con = con) %>%
    inner_join(base_trajectories, by = "id") %>%
    compute(name = "traj_catalog")
  
  results <- map_dfr(seq(20, 50, 10), \(current_n_levels) {
    
    target_heights <- height_levels(profile, current_n_levels)
    isa_profile <- generate_isa_profile(target_heights)
    
    base_h <- traj_catalog %>%
      filter(height %in% !!target_heights) %>%
      left_join(isa_profile, by = "height", copy = "inline") %>%
      compute(name = "base_tmp", temporary = TRUE)
    
    target_cellsizes <- seq(40, 400, by = 40)
    
    sources_lazy <- open_dataset(moisture_sources) %>%
      select(id, contribution, source_domain, source, dest_hydrological_zone) %>%
      to_duckdb(con = con) %>%
      inner_join(base_h %>% select(id, dz, rho), by = "id") %>%
      filter(!is.na(dest_hydrological_zone)) %>%
      mutate(water_mass_g_m2 = contribution * rho * dz) %>%
      compute(name = "sources_lazy")
    
    step_results <- map_dfr(target_cellsizes, \(current_cellsize) {
      
      deg_step <- current_cellsize / 111.32
      
      phases <- expand.grid(
          ox = c(0, 1/2) * deg_step,
          oy = c(0, 1/2) * deg_step
        ) %>%
        mutate(phase_id = row_number()) %>%
        {copy_to(con, ., name = "phases_tmp", overwrite = TRUE)}
      
      sampled_ids <- base_h %>%
        cross_join(phases) %>%
        mutate(
          lon_grid = floor((launch_lon + ox) / deg_step) * deg_step,
          lat_grid = floor((launch_lat + oy) / deg_step) * deg_step
        ) %>%
        group_by(phase_id, dest_hydrological_zone, height, lon_grid, lat_grid) %>%
        slice_sample(n = 1) %>% 
        ungroup() %>%
        select(phase_id, id)
        
      sources_lazy %>%
        inner_join(sampled_ids, by = "id") %>%
        group_by(phase_id, dest_hydrological_zone, source_domain, source) %>%
        summarise(
          raw_source_mass = sum(water_mass_g_m2, na.rm = TRUE),
          n_trajectories = n_distinct(id), 
          .groups = "drop"
        ) %>%
        group_by(dest_hydrological_zone, source_domain, source) %>%
        summarise(
          mean_raw_mass = mean(raw_source_mass, na.rm = TRUE),
          mean_n_trajectories = mean(n_trajectories, na.rm = TRUE),
          .groups = "drop"
        ) %>%
        collect() %>%
        group_by(dest_hydrological_zone) %>%
        mutate(
          total_subbasin_mass = sum(mean_raw_mass, na.rm = TRUE),
          fraction = ifelse(total_subbasin_mass > 0, mean_raw_mass / total_subbasin_mass, 0)
        ) %>%
        ungroup() %>%
        inner_join(basin_pp, by = c("dest_hydrological_zone" = "hydrological_zone")) %>%
        mutate(
          volume_km3 = fraction * precipitation_km3,
          simulation_year = sim_year,
          simulation_month = sim_month,
          n_levels = current_n_levels,
          cellsize_km = current_cellsize
        ) %>%
        select(
          simulation_year, simulation_month, dest_hydrological_zone, 
          source_domain, source, fraction, volume_km3, mean_n_trajectories, 
          n_levels, cellsize_km
        )
    })
    
    dbExecute(con, "DROP TABLE IF EXISTS base_tmp;")
    dbExecute(con, "DROP TABLE IF EXISTS sources_lazy;")
    
    return(step_results)
  })
  
  return(results)
}
