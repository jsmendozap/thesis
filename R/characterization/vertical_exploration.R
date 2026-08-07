pacman::p_load(
  'stars',
  'tidyverse',
  'here',
  'feasts',
  'tsibble',
  "lmtest",
  "sandwich"
)

smooth_data <- function(month, mean, sd, varname) {
  month_number <- as.numeric(month)
  avg <- spline(month_number, mean)
  upper <- spline(month_number, mean + sd)
  lower <- spline(month_number, mean - sd)

  tibble(
    var = varname,
    month = avg$x,
    mean = avg$y,
    ymin = lower$y,
    ymax = upper$y
  )
}

monthly_summary <- function(profile, single_levels, aoi) {
  pp <- read_stars(single_levels) %>%
    st_set_crs(4326) %>%
    .[aoi] %>%
    st_apply("time", mean, na.rm = TRUE) %>%
    as.data.frame() %>%
    mutate(
      month = month(time, label = T),
      days_in_month = days_in_month(time),
      pp = mean * 1000 * days_in_month
    ) %>%
    pivot_longer(cols = pp, names_to = "var", values_to = "value") %>%
    select(time, month, var, value)

  profile %>%
    filter(level %in% 500:1000) %>%
    pivot_longer(
      cols = c(flux, q, w),
      names_to = "var",
      values_to = "value"
    ) %>%
    group_split(var) %>%
    map(
      ~ filter(.x, if (unique(var) == "w") level %in% 500 else level %in% 850)
    ) %>%
    map(~ select(.x, time, month, var, value)) %>%
    append(list(pp)) %>%
    map(~ mutate(.x, mean = mean(value), sd = sd(value), .by = month)) %>%
    map(~ smooth_data(.x$month, .x$mean, .x$sd, .x$var[1])) %>%
    bind_rows() %>%
    ggplot(aes(x = month, y = mean, group = 1)) +
    geom_ribbon(
      aes(ymin = ymin, ymax = ymax),
      alpha = 0.2,
      fill = "steelblue4"
    ) +
    geom_line(aes(y = mean), linewidth = 0.8) +
    facet_wrap(
      ~var,
      ncol = 1,
      scales = "free_y",
      strip.position = "left",
      labeller = labeller(
        var = c(
          "flux" = "Flux (850 hPa)",
          "pp" = "Precipitation (mm)",
          "q" = "Specific Humidity (850 hPa)",
          "w" = "Vertical Velocity (500 hPa)"
        )
      )
    ) +
    scale_x_continuous(breaks = 1:12, labels = month.abb) +
    scale_y_continuous(position = "right", n.breaks = 6) +
    labs(y = "", x = "") +
    theme_bw() +
    theme(
      panel.grid.minor = element_blank()
    )

  path <- here("plots", "vertical_profile_monthly_summary.png")
  ggsave(path, height = 10)

  return(path)
}

extract_stats <- function(y, t) {
  model <- lm(y ~ t)

  NeweyWest(model, lag = 24, prewhite = FALSE) %>%
    {
      coeftest(model, vcov = .)
    } %>%
    {
      list(
        slope = pluck(., 2) * 120,
        p_value = pluck(., 8)
      )
    }
}

flux_trend <- function(profile) {
  data <- profile %>%
    mutate(ym = yearmonth(time)) %>%
    as_tsibble(key = level, index = ym) %>%
    model(
      stl = STL(flux ~ season(window = 'periodic') + trend(window = 21))
    ) %>%
    components()

  trend_summary <- data %>%
    as_tibble() %>%
    group_by(level) %>%
    mutate(
      t = row_number(),
      deseasonalized = flux - season_year
    ) %>%
    summarise(
      deseasonalized = list(deseasonalized),
      t = list(t)
    ) %>%
    rowwise() %>%
    mutate(stats = list(extract_stats(deseasonalized, t))) %>%
    unnest_wider(col = "stats") %>%
    mutate(label = sprintf("p = %.3f\n\u03b2 = %+.4f /dec", p_value, slope)) %>%
    ungroup() %>%
    filter(p_value <= 0.045)

  p1 <- data %>%
    as_tibble() %>%
    filter(level %in% trend_summary$level) %>%
    ggplot(aes(x = ym)) +
    geom_line(aes(y = flux - season_year), color = "grey75", alpha = 0.6) +
    geom_line(aes(y = trend), color = "#b2182b", linewidth = 1) +
    geom_smooth(
      aes(y = flux - season_year),
      method = "lm",
      formula = y ~ x,
      se = FALSE,
      color = "black",
      linewidth = 0.5,
      linetype = "dashed"
    ) +
    geom_label(
      data = trend_summary,
      aes(x = yearmonth("Dec 2000"), y = -0.005, label = label),
      fontface = 'bold',
      size = 3,
      color = "black",
      label.padding = unit(0.5, "lines"),
      inherit.aes = FALSE
    ) +
    scale_x_yearmonth(breaks = "4 years", date_labels = "%Y") +
    scale_y_continuous(n.breaks = 10) +
    facet_wrap(~level, nrow = 2) +
    labs(x = "", y = "Deseasonalized flux") +
    theme_bw() +
    theme(
      strip.background = element_rect(fill = "grey95")
    )

  p2 <- data %>%
    filter(level %in% 500:1000) %>%
    autoplot() +
    scale_x_yearmonth(breaks = "2 years", date_labels = "%Y") +
    theme_bw()

  p3 <- profile %>%
    filter(level %in% 200:1000) %>%
    mutate(year = as.character(year)) %>%
    ggplot(aes(y = level, group = time)) +
    geom_path(aes(x = flux, col = year), linewidth = 0.8, alpha = 0.4) +
    facet_wrap(~month) +
    scale_x_continuous(
      name = "Mean humidity flux (g/kg * m/s)"
    ) +
    labs(x = "Mean humidity flux", y = "Pressure level (hPa)") +
    theme_bw()

  path1 <- here("plots", "vertical_flux_trend.png")
  ggsave(path1, p1, height = 9, width = 16)

  path2 <- here("plots", "decomposition.png")
  ggsave(path2, p2, width = 8)

  path3 <- here("plots", "profile_complete.png")
  ggsave(path3, p3, height = 12, width = 10)

  return(c(path1, path2, path3))
}


vertical_exploration_plots <- function(profile, single_levels, aoi) {
  monthly_flux <- monthly_summary(profile, single_levels, aoi)
  trend <- flux_trend(profile)

  return(c(monthly_flux, trend))
}
