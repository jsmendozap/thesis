pacman::p_load(arrow, tidyverse, duckdb, duckspatial, DBI, here)

trajectory_duration <- function(dataset) {
    worker_tmp <- tempfile(pattern = "duckdb_", tmpdir = here("temp"))
    con <- ddbs_create_conn(threads = 4, memory_limit_gb = 5)
    worker_tmp <- tempfile(pattern = "duckdb_", tmpdir = here("temp"))

    on.exit(
        {
            dbDisconnect(con, shutdown = TRUE)
            unlink(worker_tmp, recursive = TRUE)
        },
        add = TRUE
    )

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
        rename_all(~ str_to_lower(.x)) %>%
        arrange(year, month, durations)
}
