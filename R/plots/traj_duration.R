pacman::p_load(tidyverse, here)

duration_plot <- function(duration) {

  p <- duration %>%
    mutate(
      duration = durations / 24,
      unknown_origin = unknown_origin * 100,
      year = as.factor(year)
    ) %>%
    ggplot(aes(x = duration, y = unknown_origin, group = year, col = year)) +
    geom_line(linewidth = 0.8) +
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

  ggsave("cal_trajectory_duration.png", width = 10, height = 5, path = here("plots"))
  return(here("plots", "cal_trajectory_duration.png"))
}
