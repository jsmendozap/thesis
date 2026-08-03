pacman::p_load(tidyverse, here)

moisture_profile <- function(profile){

  profile %>%
    summarise(q = mean(q), .by = level) %>%
    arrange(desc(level)) %>%
    mutate(percentage = cumsum(q)/sum(q) * 100) %>%
    filter(level == units::as_units("300 millibars")) %>%
    pull(percentage) %>%
    {sprintf("Water humidity accumulated at 300 mb: %s%%", round(., 2))} %>%
    cat()

  p <-profile %>% 
    arrange(desc(level)) %>%
    mutate(level = as.integer(level), q = cumsum(q) / sum(q)) %>%
    summarise(flux = mean(flux), q = mean(q), .by = level) %>%
    ggplot(aes(y = level)) +
    geom_path(aes(x = flux), linewidth = 0.8, col = 'darkgreen') +
    geom_point(aes(x = flux), col = "darkgreen", size = 2) +
    geom_path(aes(x = q * 0.052), linewidth = 0.8, col = 'blue', linetype = "dashed") +
    geom_point(aes(x = q * 0.052), col = "blue", size = 2) +
    scale_y_reverse(n.breaks = 20, 
                    sec.axis = sec_axis(
                      transform = ~ 8000 * log(1014 / .x) / 1000,
                      breaks = seq(0, 20, 2),
                      name = "Altitude (Km)"
                    )) +
    scale_x_continuous(
      name = "Mean humidity flux (g/kg * m/s)", 
      n.breaks = 10,
      sec.axis = sec_axis(
        transform = ~ . / 0.052,
        name = "Cumulative specific humidity from surface",
        labels = scales::percent 
      )
    ) +
    labs(x = "Mean humidity flux", y = "Pressure level (hPa)") +
    theme_bw() +
    theme(
      axis.title.x.top = element_text(color = "blue"),
      axis.title.x.bottom = element_text(color = "darkgreen")
    )
  
  ggsave("moisture_profile.png", path = here("plots"))

  return(here("plots", "moisture_profile.png"))
}



