pacman::p_load(arrow, geoarrow, sf, terra, tidyverse, here, duckspatial, rnaturalearth)

rasterize_var <- function(data) {
  raster_template <- rast(data, resolution = 0.27) 
  
  sprintf("%s", month.abb) %>%
    map(~rasterize(data, raster_template, field = .x)) %>%
    rast()
}

grid_plots <- function(source_hotspots, sources){
  
  grid <- st_bbox(c(xmin = -80, ymin = -35, xmax = 20, ymax = 30), crs = 4326) %>%
    st_transform(3857) %>%
    st_make_grid(cellsize = 30000) %>%
    st_sf(id = 1:length(.), geometry = .) %>%
    st_transform(crs = 4326)
  
  countries <- ne_countries(continent = "south america") %>% select(name)
  n_years <- open_dataset(source_hotspots) %>% distinct(year) %>% collect %>% nrow()
  
  data <- source_hotspots %>%
    open_dataset() %>% 
    to_duckdb() %>%
    group_by(id, month) %>%
    summarise(water_depth = sum(water_depth, na.rm = TRUE) / n_years, .groups = "drop") %>%
    collect() %>% 
    filter(!is.na(water_depth), water_depth > 0) %>%
    mutate(month = month(month, label = T)) %>%
    pivot_wider(
      names_from = month,
      values_from = water_depth,
      values_fill = 0
    ) %>%
    inner_join(grid) %>%
    st_as_sf(sf_column_name = 'geometry', crs = 4326) %>%
    rasterize_var()
  
  ## General plot -------------------------------------------------------------
  # FIG 1: Total moisture source, mean climatology by month.
  # Answers: where does the moisture that feeds precipitation in the study
  # area come from?. When the whole column is plotted, the spatial pattern reflects
  # the dominant low- and mid-level circulation (monsoon, ITCZ migration),
  # not only the surface sources.
  # Units: mm/month of water depth over each source cell, averaged over
  # n_years (sum of all events / n_years).
  
  p1 <- ggplot() +
    geom_spatraster_contour_filled( 
      data = data, 
      breaks = c(0.1, 0.5, 1, 5, 10, 20, 50, 100, 200)
    ) +
    geom_spatraster_contour(
      data = data,
      breaks = c(0.1, 0.5, 1, 5, 10, 20, 50, 100, 200), 
      color = "grey30",
      linewidth = 0.1
    ) +
    geom_sf(data = countries, fill = NA, color = "black") +
    facet_wrap(~lyr, ncol = 3) +
    scale_fill_viridis_d(
      option = "mako", 
      begin = 0.2,
      direction = -1,
      name = "Water supply\n(mm/month)",
      na.value = "transparent"
    ) +
    coord_sf(ylim = c(-15, 12)) +
    theme_bw()
  
  path1 <- here("plots", "grid_water_supply.png")
  ggsave(path1, p1, width = 12, height = 9)
  
  ## Transport distance -------------------------------------------------------
  # FIG 2: Cumulative share of tracked bl moisture vs distance to the
  # precipitation point (bins of 10 km, bin center as x). It shows how local
  # the surface supply is: the distance at which the curve reaches 50% or
  # 90% gives the typical range of the surface source.
  # The distance is geodesic (ST_Distance_Sphere) between the position of
  # each particle and its origin point (lat_t0, lon_t0).
  # Only bl is used, so this is the surface moisture. It does not describe
  # the transport of the moisture above the boundary layer.
  
  con <- ddbs_create_conn(threads = 25, memory_limit_gb = 100)
  curve <- sources %>% dirname %>% dirname %>% unique %>%
    open_dataset %>%
    select(lat_t0, lon_t0, source_lon, source_lat, water_mass_kg, blh_ratio) %>%
    filter(!is.na(source_lon), blh_ratio <= 1.5) %>%
    to_duckdb(con = con) %>%
    mutate(
      dist_km = ST_Distance_Sphere(
        ST_Point(lat_t0, lon_t0),
        ST_Point(source_lat, source_lon)
      ) / 1000,
      dist_bin = floor(dist_km / 10) * 10 + 5
    ) %>%
    group_by(dist_bin) %>%
    summarise(mass_kg = sum(water_mass_kg, na.rm = TRUE)) %>%
    collect() %>%
    arrange(dist_bin) %>%
    mutate(fraction_pct = 100 * mass_kg / sum(mass_kg),
           cumulative_pct = cumsum(fraction_pct))
  
  threshold_distances <- tibble(threshold_pct = c(50, 80, 90, 95, 99)) %>%
    mutate(distance_km = approx(curve$cumulative_pct, curve$dist_bin, 
                                xout = threshold_pct, ties = "ordered")$y)
  
  x_max <- max(threshold_distances$distance_km, na.rm = TRUE) * 1.15
  
  p2 <- ggplot(curve, aes(dist_bin, cumulative_pct)) +
    geom_segment(data = threshold_distances,
                 aes(x = 0, xend = distance_km, y = threshold_pct, yend = threshold_pct),
                 linetype = "dashed", colour = "grey50", inherit.aes = FALSE) +
    geom_segment(data = threshold_distances,
                 aes(x = distance_km, xend = distance_km, y = 0, yend = threshold_pct),
                 linetype = "dashed", colour = "grey50", inherit.aes = FALSE) +
    geom_line(colour = "#d95f02", linewidth = 0.8) +
    geom_label(data = threshold_distances,
               aes(x = distance_km - 110, y = threshold_pct,
                   label = sprintf("%d%% within %.0f km", threshold_pct, distance_km)),
               hjust = -0.05, 
               vjust = -0.5,  
               size = 3, linewidth = 0, inherit.aes = FALSE) +
    scale_y_continuous(breaks = seq(0, 100, 10), limits = c(0, 105), expand = c(0, 0)) +
    scale_x_continuous(breaks = seq(0, x_max, 200), expand = c(0, 0)) +
    coord_cartesian(xlim = c(0, x_max)) +
    labs(x = "Distance from the precipitation zone (km)",
         y = "Tracked accumulated moisture (% of attributed water)") +
    theme_bw()
  
  path2 <- here("plots", "distance_accumulated_moisture.png")
  ggsave(path2, p2, width = 14, height = 8)
  
  return(c(path1, path2))
}


