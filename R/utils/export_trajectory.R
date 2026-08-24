pacman::p_load(sf, DBI, duckspatial, dbplyr, tidyverse, here)

export_trj <- function(trajectories, out) {
  con <- ddbs_create_conn(threads = 4, memory_limit_gb = 5)
  worker_tmp <- tempfile(pattern = "duckdb_", tmpdir = here("temp"))
  dbExecute(con, sprintf("SET temp_directory='%s';", worker_tmp))

  on.exit(
    {
      dbDisconnect(con, shutdown = TRUE)
      unlink(worker_tmp, recursive = TRUE)
    },
    add = TRUE
  )

  query <- sprintf(
    "read_parquet('%s/*.parquet', filename = TRUE)",
    trajectories
  )

  tbl(con, query) %>%
    mutate(parts = string_split(raw_line, " ")) %>%
    filter(length(parts) == 17) %>%
    mutate(
      date = regexp_extract(
        filename,
        "traj_([0-9]{4}_[0-9]{2}_[0-9]{2}_[0-9]{2})",
        1L
      ),
      clean_date = str_replace_all(date, "_", "")
    ) %>%
    transmute(
      id = paste0(
        clean_date,
        printf("%04d", as.integer(parts[[1]]))
      ),
      date,
      lat = parts[[10L]],
      long = parts[[11]],
      height = parts[[12]],
    ) %>%
    mutate(across(2:4, ~ as.numeric(.x))) %>%
    arrange(id, date) %>%
    collect() %>%
    st_as_sf(coords = c("long", "lat", "height"), crs = 4326, dim = "XYZ") %>%
    group_by(id) %>%
    summarize(
      start = first(date),
      end = last(date),
      n = n(),
      geom = st_cast(st_combine(geometry), "LINESTRING"),
      .groups = "drop"
    ) %T>%
    {
      if (any(.$n) < 2) {
        filter(., n < 2) %>%
          pull(id) %>%
          {
            warning(
              call. = F,
              sprintf(
                "Excluding %d trayectories with <2 points: %s",
                length(.),
                paste(., collapse = ", ")
              )
            )
          }
      }
    } %>%
    filter(n > 2) %>%
    st_write(out)
}
