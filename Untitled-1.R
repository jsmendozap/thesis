library(tidyverse)
library(targets)
library(arrow)
library(terra)

data <- tar_read(land_ocean_mask) %>%
  open_dataset() %>%
  filter(!is.na(source_domain)) %>%
  select(lon_idx, lat_idx, source_domain) %>%
  transmute(
    lon = (lon_idx + 0.5) / 100,
    lat = (lat_idx + 0.5) / 100,
    source_domain
  ) %>%
  collect() %>%
  mutate(id = dense_rank(source_domain))

regions <- data %>% distinct(id, source_domain)

area_sources <- rast(
  select(data, lon, lat, id),
  type = "xyz",
  crs = "EPSG:4326"
) %>%
  expanse(byValue = T, unit = "km") %>%
  as_tibble() %>%
  rename(id = value) %>%
  left_join(regions, by = "id") %>%
  arrange(area) %>%
  select(source_domain, area)


fuentes_relevantes <- tar_read(n_particles) %>%
  # Usar la mejor resolución y solo la capa límite como verdad base
  filter(cellsize_km == 40, n_levels == "30", source == "bl") %>%
  group_by(source_domain, simulation_year) %>%
  summarise(
    volumen_anual_km3 = sum(mean_total_water_volume_km3, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  group_by(simulation_year) %>%
  mutate(porcentaje = (volumen_anual_km3 / sum(volumen_anual_km3)) * 100) %>%
  filter(porcentaje >= 0.1) %>%
  pull(source_domain) %>%
  unique


cellsize <- tar_read(n_particles) %>%
  filter(
    source_domain %in% fuentes_relevantes,
    n_levels == "30",
    source == "bl"
  ) %>%
  mutate(initial_n_sources = n_distinct(source_domain)) %>%
  group_by(source_domain, simulation_year, cellsize_km) %>%
  summarise(
    volumen_km3 = sum(mean_total_water_volume_km3, na.rm = TRUE),
    initial_n_sources = unique(initial_n_sources),
    .groups = "drop"
  ) %>%
  arrange(source_domain, simulation_year, desc(cellsize_km)) %>%
  group_by(source_domain, simulation_year) %>%
  mutate(
    delta_volumen = volumen_km3 - lag(volumen_km3),
    cambio_porcentual_vs_anterior = (delta_volumen / lag(volumen_km3)) * 100
  ) %>%
  ungroup() %>%
  filter(!is.na(cambio_porcentual_vs_anterior)) %>%
  group_by(source_domain, simulation_year) %>%
  mutate(convergence = cumsum(abs(cambio_porcentual_vs_anterior) < 1.5)) %>%
  filter(convergence == 1) %>%
  slice_head(n = 1) %>%
  ungroup() %>%
  summarise(
    source_domain = list(source_domain),
    initial_n_sources = max(initial_n_sources),
    final_n_sources = n_distinct(source_domain),
    cellsize_requerido = min(cellsize_km)
  )

area_sources %>%
  filter(!source_domain %in% cellsize$source_domain) %>%
  write.table("test.txt")


tar_read(n_particles) %>%
  drop_na() %>%
  mutate(
    # Coerción a factor ordinal con niveles estrictamente descendentes
    cellsize_fct = factor(
      cellsize_km,
      levels = sort(unique(cellsize_km), decreasing = TRUE)
    )
  ) %>%
  group_by(cellsize_fct, n_levels, simulation_month, simulation_year) %>%
  summarise(
    total_water_volume = sum(mean_total_water_volume_km3, na.rm = T)
  ) %>%
  # Inyección del parámetro 'group' obligatorio para ejes discretos
  ggplot(aes(
    x = cellsize_fct,
    y = total_water_volume,
    color = n_levels,
    lty = n_levels,
    group = n_levels
  )) +
  geom_line() +
  geom_point() +
  facet_grid(simulation_month ~ simulation_year, scales = "free_y") +
  theme_bw() +
  labs(x = "Tamaño de celda (km)")
