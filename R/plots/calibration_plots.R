pacman::p_load(tidyverse, here)

params_plots <- function(cal){
  
  config_labels <- c(
    "rain=TRUE_arrival=80_loss=0_qc=0.3" = "Rain t=0: Enabled \nRH arrival 80% \nRH loss 0%",
    "rain=FALSE_arrival=80_loss=80_qc=0.3" = "Rain t=0: Disabled \nRH arrival 80% \nRH loss 80%"
  )
  
  add_config_label <- function(data) {
    data %>% mutate(
      config_clean = factor(config, levels = names(config_labels), labels = config_labels),
      month_name   = factor(month, levels = c(3, 5, 8), labels = c("March", "May", "August"))
    )
  }
  
  p1 <- cal$ecoregions$shares %>%
    filter(source_ecoregion %in% cal$ecoregions$variation$source_ecoregion) %>%
    mutate(mean = mean(contribution_pct), .by = c(source_ecoregion, config)) %>%
    mutate(
      source_ecoregion = fct_reorder(source_ecoregion, mean),
      config_clean = factor(config, levels = names(config_labels), labels = config_labels)
    ) %>%
    ggplot(aes(y = source_ecoregion)) +
    geom_point(aes(x = contribution_pct), shape = 21, color = "gray75", fill = "gray85",
               size = 1.4, position = position_jitter(height = 0.15, width = 0)) +
    geom_point(aes(x = mean, fill = config_clean), shape = 21, color = "gray30",
               size = 2.4, position = position_dodge(width = 0.6)) +
    scale_fill_manual(values = c("#56B4E9", "#E69F00")) +
    scale_x_continuous(
      breaks = seq(0, 50, by = 5),
      labels = scales::percent_format(scale = 1)
    ) +
    labs(
      x = "Contribution to precipitation (%)",
      y = NULL,
      fill = "Configuration"
    ) +
    theme_bw(base_size = 11) +
    theme(
      legend.title = element_text(face = "bold", size = 9),
      legend.position = "bottom",
      legend.key.height = unit(1.2, "cm"),
      legend.text = element_text(size = 8)
    )
  
  p2 <- cal$checks$attribution %>% 
    drop_na(dest_hydrological_zone) %>%
    mutate(dev_ratio = ratio - 1.0) %>%
    add_config_label() %>%
    ggplot(aes(x = dest_hydrological_zone, y = dev_ratio, fill = config_clean)) +
    geom_hline(yintercept = 0.0, linetype = "solid", color = "gray30", linewidth = 0.6) +
    geom_col(position = position_dodge(width = 0.85), width = 0.65, col = "gray30") +
    facet_grid(month_name ~ year) +
    scale_fill_manual(values = c("#56B4E9", "#E69F00")) +
    scale_y_continuous(
      breaks = seq(-0.2, 0.3, by = 0.05),
      labels = scales::percent_format(accuracy = 1)
    ) +
    coord_cartesian(ylim = c(-0.1, 0.3)) +
    labs(
      x = "Hydrological zone",
      y = "Attribution Bias",
      fill = "Configuration"
    ) +
    theme_bw(base_size = 11) +
    theme(
      axis.text.x = element_text(angle = 45, hjust = 1, vjust = 1, size = 8),
      axis.text.y = element_text(size = 8),
      strip.background = element_rect(fill = "gray95"),
      legend.position = "bottom",
      legend.title = element_text(face = "bold", size = 9),
      legend.key.height = unit(1.2, "cm"),
      legend.text = element_text(size = 8),
      panel.grid.major.x = element_blank(),
      panel.grid.minor = element_blank()
    )
  
  
  p3 <- cal$checks$closure %>%
    add_config_label() %>%
    mutate(
      year = as.factor(year),
      config_clean = str_replace_all(config_clean, "\n", " | ")
    ) %>%
    ggplot(aes(x = month_name, y = closure, fill = year)) +
    geom_hline(yintercept = 1.0, linetype = "dashed", color = "firebrick", linewidth = 0.6) +
    geom_violin(
      position = position_dodge(width = 0.8),
      width = 0.75,
      color = "gray25",
      linewidth = 0.35,
      alpha = 0.85,
      scale = "width",
      trim = TRUE,
      draw_quantiles = c(0.5, 0.9)
    ) +
    facet_wrap(~ config_clean, scales = "free_y", ncol = 2) +
    scale_fill_brewer(palette = "Set2") +
    labs(
      x = "",
      y = "Mass clossure",
      fill = "Year"
    ) +
    coord_cartesian(ylim = c(0, 2)) +
    theme_bw(base_size = 11) +
    theme(
      strip.background = element_rect(fill = "gray92"),
      strip.text = element_text(face = "bold", size = 8.5),
      legend.position = "bottom",
      legend.title = element_text(face = "bold", size = 9),
      legend.text = element_text(size = 8.5),
      panel.grid.major.x = element_blank(),
      panel.grid.minor = element_blank()
    )
  
  
  p4 <- cal$checks$vs_observed %>%
    drop_na(dest_hydrological_zone) %>%
    filter(config != "rain_none_arrival80_loss80") %>%
    mutate(dev_ratio = ratio - 1.0) %>%
    add_config_label() %>%
    ggplot(aes(x = dest_hydrological_zone, y = dev_ratio, fill = config_clean)) +
    geom_hline(yintercept = 0.0, linetype = "solid", color = "gray30", linewidth = 0.6) +
    geom_col(position = position_dodge(width = 0.85), width = 0.65, color = "gray30") +
    facet_grid(month_name ~ year) +
    scale_fill_manual(values = c("#56B4E9", "#E69F00")) +
    scale_y_continuous(labels = scales::percent_format(accuracy = 1), breaks = seq(-0.5, 4, 0.5)) +
    labs(
      x = "Hydrological zone",
      y = "Precipitation Bias",
      fill = "Configuration"
    ) +
    theme_bw(base_size = 11) +
    theme(
      axis.text.x = element_text(angle = 45, hjust = 1, vjust = 1, size = 8),
      axis.text.y = element_text(size = 8),
      legend.position = "bottom",
      legend.title = element_text(face = "bold", size = 9),
      legend.key.height = unit(1.2, "cm"),
      legend.text = element_text(size = 8),
      panel.grid.minor = element_blank()
    )
  
  path1 <- here("plots", "cal_contribution_ecoregions.png")
  path2 <- here("plots", "cal_attribution.png")
  path3 <- here("plots", "cal_mass_closure.png")
  path4 <- here("plots", "cal_precipitation.png")
  
  ggsave(path1, p1, width = 11, height = 7)
  ggsave(path2, p2, width = 11, height = 7)
  ggsave(path3, p3, width = 9, height = 5)
  ggsave(path4, p4, width = 11, height = 7)
  
  return(c(path1, path2, path3, path4))
}