pacman::p_load(sf, arrow, tidyverse, targets)

check_trj <- function(trajectory) {
  
  open_dataset(trajectory) %>%
    mutate(
      year = basename(trajectory) %>% substr(6, 9),
      date = make_datetime(year, month, day, hour, minute)
    ) %>%
    select(traj_id, date, height, lat, long) %>%
    arrange(traj_id, date) %>%
    collect() %>%
    st_as_sf(coords = c("long", "lat", "height"), crs = 4326, dim = "XYZ") %>%
    group_by(traj_id) %>%
    summarize(
      start = first(date),
      end = last(date),
      n = n(),
      geom = st_cast(st_combine(geometry), "LINESTRING"),
      .groups = "drop"
    ) %T>%
    {
      if (any(.$n) < 2) {
        filter(., n < 2) %>% pull(traj_id) %>%
        {warning(call. = F, sprintf("Excluding %d trayectories with <2 points: %s",
                 length(.), paste(., collapse = ", ")))}
      }
    } %>%
    filter(n > 2)
}

pacman::p_load(DBI, duckdb, dplyr, dbplyr, here)

create_path <- function(year) {
  con <- dbConnect(duckdb())
  
  on.exit({
    dbDisconnect(con, shutdown = TRUE)
  }, add = TRUE)

  dbExecute(con, "SET memory_limit='6GB';")
  dbExecute(con, "SET threads=6;")
  dbExecute(con, "INSTALL spatial; LOAD spatial;")

  year_int <- as.integer(year)
  gpkg_file <- here("output", sprintf("trajectories_%s.gpkg", year))
  trajectories <- dir(here("data", "trajectories"), pattern = paste0("traj_", year), full.names = TRUE)

  for (trajectory in trajectories) {
    layer <- substr(basename(trajectory), 1, 18)

    open_dataset(trajectory, format = "parquet") %>%
      to_duckdb(con = con) %>%
      mutate(date = make_timestamp(!!year_int, month, day, hour, minute, 0.0)) %>%
      group_by(traj_id) %>%
      mutate(n = n()) %>%
      filter(n > 2) %>%
      summarize(
        start = min(date, na.rm = TRUE),
        end = max(date, na.rm = TRUE),
        geometry = sql("ST_AsWKB(
                          ST_GeomFromText(
                            'LINESTRING Z (' ||
                            string_agg(long || ' ' || lat || ' ' || height, ', ' ORDER BY date) ||
                            ')'
                          )
                        )"),
        .groups = "drop"
      ) %>%
      collect() %>%
      st_as_sf(crs = 4326) %>%
      st_write(gpkg_file, layer)
  }
}

