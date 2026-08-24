pacman::p_load(
  arrow,
  tidyverse,
  duckdb,
  DBI,
  targets,
  dbplyr,
  here,
  sf,
  jsonlite
)

grid_convergence <- function(profile, moisture_sources, config) {
  con <- dbConnect(duckdb())
  worker_tmp <- tempfile(pattern = "duckdb_", tmpdir = here("temp"))

  on.exit(
    {
      dbDisconnect(con, shutdown = TRUE)
      unlink(worker_tmp, recursive = TRUE)
    },
    add = TRUE
  )

  dbExecute(con, sprintf("SET temp_directory='%s';", worker_tmp))

  scenarios <- expand_grid(
    step = 1:10,
    current_n_levels = c(20, 30)
  ) %>%
    mutate(
      offset_x = map(step, ~ 0:(.x - 1)),
      offset_y = map(step, ~ 0:(.x - 1))
    ) %>%
    unnest(offset_x) %>%
    unnest(offset_y)

  heights_30 <- height_levels(profile, 30)
  heights_20 <- heights_30[round(seq(1, 30, length.out = 20))]

  grid_reference <- read_json(config, simplifyVector = T)$control$points %>%
    mutate(
      across(3:4, ~ round(.x, 3)),
      lon_min = lon - 0.001,
      lon_max = lon + 0.001,
      lat_min = lat - 0.001,
      lat_max = lat + 0.001,
      h_min = height - 45,
      h_max = height + 45
    )

  dbWriteTable(con, "grid_index", grid_reference, overwrite = TRUE)

  base_indexed <- str_replace(moisture_sources, "output", "data") %>%
    open_dataset() %>%
    to_duckdb(con = con) %>%
    mutate(parts = string_split(raw_line, " ")) %>%
    filter(length(parts) == 7) %>%
    transmute(
      id,
      lat = parts[[5]],
      lon = parts[[6]],
      height = parts[[7]]
    ) %>%
    mutate(across(2:4, as.numeric)) %>%
    inner_join(
      tbl(con, "grid_index"),
      by = join_by(
        between(height, h_min, h_max),
        between(lat, lat_min, lat_max),
        between(lon, lon_min, lon_max)
      )
    ) %>%
    select(id, lat = lat.x, lon = lon.x, height = height.y, x_idx, y_idx) %>%
    compute(name = "indexed_trajectories", temporary = TRUE)

  results <- pmap_dfr(scenarios, \(step, current_n_levels, offset_x, offset_y) {
    target_heights <- if (current_n_levels == 30) heights_30 else heights_20

    subset_grid <- base_indexed %>%
      filter(
        (x_idx + offset_x) %% step == 0,
        (y_idx + offset_y) %% step == 0,
        height %in% target_heights
      )

    n_horizontal_points <- subset_grid %>%
      distinct(lon, lat) %>%
      count() %>%
      pull()

    if (n_horizontal_points < 2) {
      return(tibble())
    }

    valid_ids <- subset_grid %>%
      select(id, height) %>%
      collect()

    isa_profile <- generate_isa_profile(target_heights)
    n_actual_trajectories <- nrow(valid_ids)
    cell_area_m2 <- (step * 40000)^2

    open_dataset(moisture_sources) %>%
      filter(id %in% valid_ids$id) %>%
      select(id, source, source_domain, contribution) %>%
      collect() %>%
      left_join(valid_ids, by = "id") %>%
      left_join(isa_profile, by = "height") %>%
      mutate(
        air_mass_kg = cell_area_m2 * dz * rho,
        water_volume_km3 = ((contribution / 1000) * air_mass_kg) / 1e12
      ) %>%
      group_by(source_domain, source) %>%
      summarise(
        total_water_volume_km3 = sum(water_volume_km3, na.rm = TRUE),
        .groups = "drop"
      ) %>%
      mutate(
        grid_step = step,
        cellsize_km = step * 40,
        n_levels = as.character(current_n_levels),
        offset_id = paste(offset_x, offset_y, sep = "_"),
        n_horizontal_points = n_horizontal_points,
        total_trajectories = n_actual_trajectories,
        simulation_year = str_extract(moisture_sources, "(?<=year=)[0-9]{4}"),
        simulation_month = str_extract(moisture_sources, "(?<=month=)[0-9]{2}")
      )
  })

  results %>%
    group_by(
      grid_step,
      cellsize_km,
      n_levels,
      source_domain,
      source,
      simulation_year,
      simulation_month
    ) %>%
    summarise(
      mean_horizontal_points = mean(n_horizontal_points),
      mean_total_water_volume_km3 = mean(total_water_volume_km3),
      .groups = "drop"
    )
}
