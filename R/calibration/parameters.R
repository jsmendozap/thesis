pacman::p_load(tidyverse, zoo)

simulation_parameters <- function(duration, n_particles, duration_threshold, trj_threshold) {
    max_duration <- duration %>%
        arrange(year, month, durations) %>%
        group_by(year, month) %>%
        mutate(marginal_gain = lag(unknown_origin) - unknown_origin) %>%
        filter(marginal_gain < duration_threshold) %>%
        slice_head(n = 1) %>%
        ungroup() %>%
        pull(durations) %>%
        max()

    # Evaluates the stability of moisture source attribution across spatial resolutions.
    # It measures how much the fractional contribution of different sources changes 
    # when the cell size is reduced. 
    regional_change <- n_particles %>%
      group_by(simulation_year, simulation_month, cellsize_km, n_levels, source_domain) %>%
      summarise(
        regional_volume_km3 = sum(volume_km3, na.rm = TRUE),
        .groups = "drop"
      ) %>%
      group_by(simulation_year, simulation_month, cellsize_km, n_levels) %>%
      # total_regional_volume: Total precipitation volume over the entire AOI.
      # fraction_regional: Percentage of contribution from each source to the total volume.
      mutate(
        total_regional_volume = sum(regional_volume_km3, na.rm = TRUE),
        fraction_regional = ifelse(total_regional_volume > 0, regional_volume_km3 / total_regional_volume, 0)
      ) %>%
      # Order by descending cell size (e.g., 400 -> 360 -> ... -> 40) 
      # to compute the step difference against the previous, coarser resolution.
      arrange(simulation_year, simulation_month, n_levels, source_domain, desc(cellsize_km)) %>%
      group_by(simulation_year, simulation_month, n_levels, source_domain) %>%
      # step_diff: Absolute magnitude of change in source assignment between resolution steps.
      mutate(
        fraction_prev = lag(fraction_regional),
        step_diff = abs(fraction_regional - fraction_prev)
      ) %>%
      filter(!is.na(step_diff)) %>%
      group_by(simulation_year, simulation_month, cellsize_km, n_levels) %>%
      # Aggregate spatial instability across all sources.
      # Dividing by 2 prevents double counting the mass transfer within the closed system.
      summarise(regional_step_change = sum(step_diff) / 2, .groups = "drop")

    max_trajectories <- regional_change %>%
      # Sequential order from coarse to fine resolution
      arrange(simulation_year, simulation_month, n_levels, desc(cellsize_km)) %>%
      group_by(simulation_year, simulation_month, n_levels) %>%
      # Backward rollmean to ensure "stability" over a 3-step rolling window
      mutate(rollmean = zoo::rollmean(regional_step_change, 3, NA, align = "right")) %>%
      filter(!is.na(rollmean)) %>%
      arrange(simulation_year, simulation_month, n_levels, cellsize_km) %>%
      # Propagate the worst error from finer scales using cummax.
      # If 40 km has an error > 2.5%, coarser resolutions (80, 120 km) fail automatically.
      mutate(worst_error = cummax(rollmean)) %>%
      # Require the cell size and all subsequent finer resolutions to meet the threshold
      filter(worst_error <= trj_threshold) %>%
      # Select the coarsest (most computationally efficient) valid cell size for each scenario
      arrange(simulation_year, simulation_month, n_levels, desc(cellsize_km)) %>% 
      slice_head(n = 1) %>%
      ungroup() %>%
      count(n_levels, cellsize_km) %>%
      arrange(desc(n)) %>%
      slice_head(n = 1)

    list(
        max_duration = max_duration,
        max_trajectories = max_trajectories,
        regional_change = regional_change
    )
}
