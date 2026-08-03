pacman::p_load(arrow, tidyverse, duckdb, duckspatial, DBI, here, zoo)

trajectory_points <- function(dataset) {
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

    # Map trajectories by launch time and altitude layer (1, 2, 3...)
    traj_map <- dataset %>%
        str_replace("output", "data") %>%
        open_dataset() %>%
        to_duckdb(con = con) %>%
        filter(age == 0) %>%
        select(id, height) %>%
        mutate(launch_id = str_sub(id, 1, 10)) %>%
        group_by(launch_id) %>%
        # Rank trajectories from lowest to highest altitude
        window_order(height) %>%
        # The 'dense_rank' function assigns a unique number (1, 2, 3...) to each altitude level.
        mutate(level = dense_rank(height)) %>%
        ungroup() %>%
        select(id, launch_id, level) %>%
        collect()

    # Pre-calculate the total moisture fraction each trajectory brings from each location
    trajectory_contributions <- open_dataset(dataset) %>%
        to_duckdb(con = con) %>%
        select(id, location, fractional_contribution) %>%
        group_by(id, location) %>%
        summarise(fractional_trajectory_contribution = sum(fractional_contribution, na.rm = TRUE), .groups = "drop") %>%
        collect()

    # Define sample sizes (30 to 3000) and run 100 random tests for each size.
    grid <- expand_grid(size = seq(30, 3000, 30), iteration = 1:100)

    results <- map2_dfr(grid$size, grid$iteration, function(size, iteration) {
        # Pick a balanced random sample across all launch times (individual files) and altitudes
        sampled_ids <- traj_map %>%
            group_by(launch_id, level) %>%
            slice_sample(n = size / 30, replace = FALSE) %>%
            ungroup() %>%
            pull(id)

        # Calculate moisture percentages for each location in each specific random sample
        trajectory_contributions %>%
            filter(id %in% sampled_ids) %>%
            group_by(location) %>%
            # Sum up the moisture fractions for each location.
            # This tells us how much water came from this location in this specific sample.
            summarise(
                moisture_by_location = sum(fractional_trajectory_contribution, na.rm = TRUE),
                .groups = "drop"
            ) %>%
            mutate(
                # Sum the total fractional mass captured across all locations in this sample
                total_moisture_sample = sum(moisture_by_location, na.rm = TRUE),
                # Calculate the percentage contribution for each location
                relative_location_contribution = moisture_by_location / total_moisture_sample,
                size = size,
                iteration = iteration,
                year = as.integer(str_match(dataset, "year=(\\d{4})")[, 2]),
                month = str_match(dataset, "month=([a-z]+)")[, 2]
            ) %>%
            select(year, month, location, relative_location_contribution, size, iteration)
    })

    # Calculate the Coefficient of Variation (CV) for the Ocean moisture.
    # A high CV means the results change drastically depending on which trajectories were picked.
    # As the 'size' increases, the CV should drop and stabilize near zero.
    results %>%
        # Stability is evaluated using only the Ocean data.
        # Because the Ocean is the most distant and highly variable moisture source,
        # if the Ocean's variance stabilizes, the continental sources will be stable too.
        filter(location == "Ocean") %>%
        group_by(year, month, size) %>%
        summarise(
            mean = mean(relative_location_contribution),
            sd = sd(relative_location_contribution),
            .groups = "drop"
        ) %>%
        mutate(
            cv = (sd / mean) * 100,
            month = factor(month, levels = c("march", "may", "july")),
            year = as.factor(year)
        )
}
