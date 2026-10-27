pacman::p_load(
  'terra',
  'tidyverse',
  'tidyterra',
  'sf',
  'exactextractr',
  'here',
  'feasts',
  'tsibble',
  "lmtest",
  "sandwich",
  "ggtext"
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
  pp <- rast(single_levels) %>% 
    select(starts_with("tp")) %>% 
    crop(aoi) %>%
    exact_extract(
      st_union(aoi), 
      fun = "mean"
    ) %>%
    pivot_longer(
      cols = starts_with("mean"),
      names_to = "time",
      names_prefix = "mean.Y", 
      values_to = "mean"
    ) %>%
    mutate(
      time = seq(ymd("1995-01-01"), ymd("2025-12-31"), by = "1 month"),
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

  profile_overview <- profile %>%
    mutate(
      ws = sqrt(u^2 + v^2),
      ym = yearmonth(time)
    ) %>%
    select(ym, level, flux, q, ws) %>%
    pivot_longer(
      cols = c(flux, q, ws),
      names_to = "variable",
      values_to = "value"
    ) %>%
    mutate(value = ifelse(variable != "ws", value * 100, value)) %>%
    as_tsibble(key = c(level, variable), index = ym) %>%
    model(
      stl = STL(value ~ season(window = "periodic") + trend(window = 21))
    ) %>%
    components() %>%
    as_tibble()

  pos <- profile_overview %>%
    group_by(level, variable) %>%
    mutate(
      t = row_number(),
      deseasonalized = value - season_year
    ) %>%
    summarise(
      deseasonalized = list(deseasonalized),
      t = list(t)
    ) %>%
    rowwise() %>%
    mutate(stats = list(extract_stats(deseasonalized, t))) %>%
    unnest_wider(col = "stats") %>%
    ungroup() %>%
    mutate(
      significance = case_when(
        p_value < 0.001 ~ "***",
        p_value < 0.01 ~ "**",
        p_value < 0.05 ~ "*",
        TRUE ~ ""
      ),
      slope_scaled = scale(slope)[, 1],
      .by = variable
    ) %>%
    mutate(
      slope_plot = if_else(p_value <= 0.05, slope_scaled, NA_real_),
      variable = factor(
        variable,
        levels = c("flux", "ws", "q"),
        labels = c("Moisture\nFlux", "Wind\nVelocity", "Specific\nHumidity")
      )
    )

  y_borders <- seq(0.5, length(unique(pos$level)) + 0.5, by = 1)

  p2 <- ggplot(
    pos,
    aes(x = variable, y = level, fill = slope_plot)
  ) +
    geom_tile(width = 0.7) +
    geom_hline(yintercept = y_borders, color = "grey90", linewidth = 0.3) +
    geom_text(
      aes(label = significance),
      color = "black",
      size = 4,
      vjust = 0.75
    ) +
    scale_fill_gradient2(
      low = "#b2182b",
      mid = "#f7f7f7",
      high = "#2166ac",
      midpoint = 0,
      na.value = "transparent",
      name = "Slope\n(Standarized)",
      guide = guide_colorbar(barwidth = unit(8, "cm"))
    ) +
    labs(x = NULL, y = "Pressure levels (hPa)") +
    theme_minimal() +
    theme(
      panel.grid = element_blank(),
      aspect.ratio = 1.5,
      axis.text.x = element_text(face = "bold", size = 10),
      axis.text.y = element_text(size = 8),
      legend.title = element_text(size = 9, hjust = 0.5, vjust = 0.8),
      legend.text = element_text(size = 8),
      legend.position = "bottom"
    )

  profile_trend_summary <- profile_overview %>%
    filter(level %in% c(775, 950)) %>%
    mutate(level = factor(level)) %>%
    group_by(level, variable) %>%
    mutate(
      t = row_number(),
      deseasonalized = value - season_year
    ) %>%
    summarise(
      deseasonalized = list(deseasonalized),
      t = list(t)
    ) %>%
    rowwise() %>%
    mutate(stats = list(extract_stats(deseasonalized, t))) %>%
    unnest_wider(col = "stats") %>%
    mutate(
      label = sprintf("p = %.3f\n\u03b2 = %+.4f /dec", p_value, slope),
      y_pos = c(6, 1, 5.5, 0.4, 1.6, 0.5),
    ) %>%
    ungroup()

  p3 <- profile_overview %>%
    filter(level %in% c(775, 950)) %>%
    mutate(level = factor(level)) %>%
    ggplot(aes(x = ym)) +
    geom_line(aes(y = value - season_year), color = "grey75", alpha = 0.6) +
    geom_line(aes(y = trend), color = "#b2182b", linewidth = 1) +
    geom_smooth(
      aes(y = value - season_year),
      method = "lm",
      formula = y ~ x,
      se = FALSE,
      color = "black",
      linewidth = 0.5,
      linetype = "dashed"
    ) +
    geom_label(
      data = profile_trend_summary,
      aes(x = yearmonth("Dec 2000"), y = y_pos, label = label),
      fontface = 'bold',
      size = 3,
      color = "black",
      label.padding = unit(0.5, "lines"),
      inherit.aes = FALSE
    ) +
    scale_x_yearmonth(breaks = "4 years", date_labels = "%Y") +
    scale_y_continuous(n.breaks = 10, position = "right") +
    facet_grid(
      variable ~ level,
      scales = 'free_y',
      switch = "y",
      labeller = labeller(
        variable = c(
          "flux" = "Moisture Flux<br>(<span style='font-size:8pt;'>10<sup>-2</sup> kg/kg · m/s</span>)",
          "q" = "Specific Humidity<br>(<span style='font-size:8pt;'>10<sup>-2</sup> kg/kg</span>)",
          "ws" = "Wind Velocity<br>(<span style='font-size:8pt;'>m/s</span>)"
        ),
        level = c(
          "950" = "950 hPa",
          "775" = "775 hPa"
        )
      )
    ) +
    labs(x = "", y = "") +
    theme_bw() +
    theme(
      strip.background = element_rect(fill = "grey95"),
      strip.text.y.left = element_markdown(lineheight = 1)
    )

  p4 <- data %>%
    filter(level %in% 500:1000) %>%
    autoplot() +
    scale_x_yearmonth(breaks = "2 years", date_labels = "%Y") +
    theme_bw()

  p5 <- profile %>%
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

  path2 <- here("plots", "profile_mult_vars.png")
  ggsave(path2, p2, widt = 7, height = 10)

  path3 <- here("plots", "profile_trend_summary.png")
  ggsave(path3, p3, height = 9, width = 8)

  path4 <- here("plots", "decomposition.png")
  ggsave(path4, p4, width = 8)

  path5 <- here("plots", "profile_complete.png")
  ggsave(path5, p5, height = 12, width = 10)

  return(c(path1, path2, path3, path4, path5))
}


vertical_exploration_plots <- function(profile, single_levels, aoi) {
  monthly_flux <- monthly_summary(profile, single_levels, aoi)
  trend <- flux_trend(profile)

  return(c(monthly_flux, trend))
}
