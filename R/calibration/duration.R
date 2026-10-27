pacman::p_load(arrow, tidyverse, duckdb, duckspatial, DBI, here)

trajectory_duration <- function(dataset) {
    worker_tmp <- tempfile(pattern = "duckdb_", tmpdir = here("temp"))
    con <- ddbs_create_conn(threads = 6, memory_limit_gb = 80)

    on.exit(
        {
            dbDisconnect(con, shutdown = TRUE)
            unlink(worker_tmp, recursive = TRUE)
            gc(full = T)
        },
        add = TRUE
    )

    dbExecute(con, sprintf("SET temp_directory='%s';", worker_tmp))

    # Define time limits from 1 to 15 days (in hours) to test how trajectory length affects the results
    cuts <- tibble(durations = seq(24, 360, 24))
    duckdb_register(con, "temporal_cuts", cuts)

    simulation_year <- str_extract(dataset, "(?<=year=)[0-9]{4}")
    simulation_month <- str_extract(dataset, "(?<=month=)[0-9]{2}")

    base_tbl <- open_dataset(dataset) %>%
        to_duckdb(con = con)

    # Count all unique trajectories arriving at the destination.
    total_trajectories <- base_tbl %>%
        summarise(n = n_distinct(id, na.rm = TRUE)) %>%
        pull(n)

    base_tbl %>%
        # Match each moisture event with every duration threshold
        cross_join(tbl(con, "temporal_cuts")) %>%
        # Restrict thermodynamic history to the evaluated backward duration threshold.
        filter(age >= -durations) %>%
        mutate(location = if_else(is_ocean, "Ocean", "Land")) %>%
        group_by(durations, location) %>%
        # Calculate the relative moisture contribution of each source
        summarise(
            fraction = sum(fractional_contribution, na.rm = TRUE) /
                total_trajectories,
            source_points = n(),
            .groups = "drop"
        ) %>%
        collect() %>%
        pivot_wider(
            names_from = location,
            values_from = c(fraction, source_points),
            values_fill = list(fraction = 0, source_points = 0)
        ) %>%
        mutate(
            # Calculate what is missing to reach 100%. This is the moisture from uncaptured sources.
            unknown_origin = 1 - (fraction_Land + fraction_Ocean),
            year = simulation_year,
            month = simulation_month
        ) %>%
        rename_all(~ str_to_lower(.x)) %>%
        arrange(year, month, durations)
}
