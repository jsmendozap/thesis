pacman::p_load(tidyverse, here)

calibration_plots <- function(duration, n_particles, params) {

  p <- duration %>%
    mutate(
      duration = durations / 24,
      unknown_origin = unknown_origin * 100,
      year = as.factor(year)
    ) %>%
    ggplot(aes(x = duration, y = unknown_origin, group = year, col = year)) +
    geom_line(linewidth = 0.8) +
    geom_vline(
      xintercept = params$max_duration / 24,
      col = "grey30",
      linetype = "dashed",
      linewidth = 0.4
    ) +
    scale_x_continuous(breaks = 1:15) +
    scale_y_continuous(breaks = seq(0, 70, 5)) +
    scale_color_manual(
      labels = c("2000 (La Niña)", "2014 (Neutral)", "2015 (El Niño)"),
      values = c("#0072B2", "#E69F00", "#009E73")
    ) +
    labs(
      x = "Trajectory duration (days)",
      y = "Unknown origin (%)",
      color = "Year"
    ) +
    facet_wrap(
      ~month,
      labeller = labeller(
        month = c(
          "08" = "August (Dry season)",
          "03" = "March (Wet season)",
          "05" = "May (Transition)"
        )
      )
    ) +
    theme_bw() +
    theme(
      legend.position = "bottom",
      strip.background = element_rect(fill = "grey90", color = "black")
    )

  ggsave("trajectory_duration.png", width = 10, height = 5, path = here("plots"))

  ## ------------------------------------------------------------------------------------

  p1 <- params$regional_change %>%
    ggplot(aes(x = cellsize_km, y = regional_step_change, color = as.factor(n_levels))) +
    geom_line() +
    geom_point() +
    facet_grid(simulation_year ~ simulation_month,
               labeller = labeller(
                 simulation_month = c(
                   "03" = "March (Wet season)",
                   "05" = "May (Transition)",
                   "08" = "August (Dry season)"
                 )
               )) +
    scale_y_continuous(labels = scales::percent_format()) +
    scale_x_reverse(breaks = seq(40, 400, 40)) +
    labs(
      x = "Cell size (km)",
      y = "Source attribution change relative to previous step",
      color = "Vertical levels"
    ) +
    theme_bw() +
    theme(
      legend.position = "bottom",
      strip.text = element_text(face = "bold")
    )

  ggsave(
    "trj_stability.png",
    width = 10,
    height = 8,
    path = here("plots")
  )

  # Evaluates spatial stability at the basin level.
  # The core logic mirrors the regional temporal analysis, but it aggregates 
  # and averages the attribution errors across all simulated months and years.
  # This isolates the overall grid convergence behavior inherent to each specific basin.
  p2 <- n_particles %>%
    group_by(simulation_year, simulation_month, dest_hydrological_zone, cellsize_km, n_levels, source_domain) %>%
    summarise(volume_km3 = sum(volume_km3, na.rm = TRUE), .groups = "drop") %>%
    
    group_by(simulation_year, simulation_month, dest_hydrological_zone, cellsize_km, n_levels) %>%
    mutate(fraction = volume_km3 / sum(volume_km3, na.rm = TRUE)) %>%
    
    arrange(dest_hydrological_zone, simulation_year, simulation_month, n_levels, source_domain, desc(cellsize_km)) %>%
    group_by(dest_hydrological_zone, simulation_year, simulation_month, n_levels, source_domain) %>%
    mutate(step_diff = abs(fraction - lag(fraction))) %>%
    filter(!is.na(step_diff)) %>%
    
    group_by(dest_hydrological_zone, simulation_year, simulation_month, cellsize_km, n_levels) %>%
    summarise(basin_step_change = sum(step_diff)/2, .groups = "drop") %>%
    
    group_by(dest_hydrological_zone, cellsize_km, n_levels) %>%
    summarise(mean_step_change = mean(basin_step_change, na.rm = TRUE), .groups = "drop") %>%
    
    ggplot(aes(x = cellsize_km, y = mean_step_change, color = as.factor(n_levels))) +
    geom_line() + 
    geom_point() +
    facet_wrap(~dest_hydrological_zone, scales = "free_y") +
    scale_y_continuous(labels = scales::percent_format()) +
    scale_x_reverse(breaks = seq(40, 400, 40)) +
    labs(
      x = "Cell size (km)",
      y = "Source attribution change relative to previous step",
      color = "Vertical levels"
    ) +
    theme_bw() +
    theme(
      legend.position = "bottom",
      strip.text = element_text(face = "bold")
    )

  ggsave("trj_stability_basins.png", width = 12, height = 10, path = here("plots"))

  return(
    c(
      here("plots", "trajectory_duration.png"),
      here("plots", "trj_stability.png"),
      here("plots", "trj_stability_basins.png")
    )
  )
}
