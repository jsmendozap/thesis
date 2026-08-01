pacman::p_load(tidyverse, here)

calibration_plots <- function(duration, points) {

  params <- simulation_parameters(duration, points)

  p <- duration %>%
    mutate(
      duration = durations/24, 
      unknown_origin = unknown_origin * 100,
      month = factor(month, levels = c("march", "may", "july")),
      year = as.factor(year)
    ) %>%
    ggplot(aes(x = duration, y = unknown_origin, group = year, col = year)) + 
    geom_line(linewidth = 0.8) +
    geom_vline(xintercept = params$max_duration / 24, col = "grey30", linetype = "dashed", linewidth = 0.4) +
    scale_x_continuous(breaks = 1:15) +
    scale_y_continuous(breaks = seq(0, 70, 5)) +
    scale_color_manual(
      labels = c("2000 (La Niña)", "2014 (Neutral)", "2015 (El Niño)"),
      values = c("#0072B2", "#E69F00", "#009E73") 
    ) +
    labs(x = "Trajectory duration (days)", y = "Unknown origin (%)", color = "Year") +
    facet_wrap(
      ~month,
      labeller = labeller(month = c("july" = "July (Dry season)",
                                    "march" = "March (Wet season)",
                                    "may" = "May (Transition)")
                          )
      ) +
    theme_bw() + 
    theme(
      legend.position = "bottom",
      strip.background = element_rect(fill = "grey90", color = "black")
    )

  ggsave("trajectory_duration.png", width = 9, height = 5, path = here("plots"))


  ## ------------------------------------------------------------------------------------

    
  p1 <- ggplot(params$points_smooth, aes(x = size, y = max_delta)) +
    geom_line() +
    geom_point(size = 0.8) +
    geom_hline(yintercept = 0.25, linetype = 2, color = 'gray') +
    scale_x_continuous(breaks = seq(0, 3000, 300)) +
    scale_y_continuous(breaks = seq(0, 4, 0.5)) +
    labs(y = "Marginal CV reduction", x = "Number of trajectories") +
    theme_bw()

  ggsave("marginal_cv_reduction.png", width = 7, height = 4, path = here("plots"))

  p2 <- ggplot(points, aes(x = size, y = cv, color = year)) +
      geom_line(linewidth = 1) +
      geom_vline(xintercept = params$max_trajectories, linetype = "dashed", color = "black", alpha = 0.6) +
      facet_wrap(~month,
        labeller = labeller(month = c("july" = "July (Dry season)",
                                      "march" = "March (Wet season)",
                                      "may" = "May (Transition)")
                            )
                ) +
      scale_x_continuous(breaks = seq(0, 3000, 300)) +
      scale_y_continuous(breaks = seq(0, 24, 2)) +
      scale_color_manual(
        labels = c("2000 (La Niña)", "2014 (Neutral)", "2015 (El Niño)"),
        values = c("#0072B2", "#E69F00", "#009E73") 
      ) + 
      labs(
        x = "Number of trajectories per launch",
        y = "Coefficient of Variation (%)"
      ) +
      theme_bw() +
      theme(
        legend.position = "bottom",
        strip.background = element_rect(fill = "grey90", color = "black")
      )

  ggsave("trajectory_points.png", width = 12, height = 5, path = here("plots"))

  return(
    c(
      here("plots", "trajectory_duration.png"),
      here("plots", "trajectory_points.png"), 
      here("plots", "marginal_cv_reduction.png")
    )
  )
}
