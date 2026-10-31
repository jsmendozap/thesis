pacman::p_load(arrow, tidyverse, units, jsonlite)

check_attribution <- function(ds, blh_limit) {
  blh_ok <- if (blh_limit) expr(blh_ratio <= 1.5) else expr(TRUE)
  
  ds %>%
    filter(!is.na(hydrological_zone)) %>%
    group_by(year, month, hydrological_zone) %>%
    summarise(
      precip_kg = sum(precipitation_kg, na.rm = TRUE),
      attributed_kg = sum(ifelse(!!blh_ok, water_mass_kg, 0), na.rm = TRUE),
      .groups = "drop"
    ) %>%
    mutate(ratio = attributed_kg / precip_kg) %>%
    collect()
}

check_closure <- function(ds) {
  ds %>%
    filter(!is.na(hydrological_zone)) %>%
    group_by(year, month, hydrological_zone, id) %>%
    summarise(closure = sum(fractional_contribution, na.rm = TRUE), .groups = "drop") %>%
    collect()
}

check_vs_p_observed <- function(ds, p_observed, coverage) {
  observed <- open_dataset(p_observed) %>% collect
  
  ds %>%
    filter(age == 0, !is.na(hydrological_zone)) %>%
    group_by(year, month, hydrological_zone) %>%
    summarise(precip_kg = sum(precipitation_kg, na.rm = TRUE), .groups = "drop") %>%
    collect() %>%
    left_join(observed, by = c("year", "month", "hydrological_zone")) %>%
    left_join(coverage, by = "hydrological_zone") %>%
    mutate(
      estimated = set_units(precip_kg / (sampled_area_km2 * 1e6), "mm"),  
      observed = precipitation,
      ratio = drop_units(estimated / observed)
    ) %>%
    select(year, month, hydrological_zone, estimated, observed, ratio)
}

check_vs_e_observed <- function(ds, e_observed, coverage, ecoregions, blh_limit) {
  
  blh_filter <- if (blh_limit) expr(blh_ratio <= 1.5) else expr(TRUE)
  observed <- open_dataset(e_observed) %>% collect
  
  ds %>%
    filter(age < 0, !is.na(hydrological_zone), !!blh_filter) %>%
    group_by(year, month, hydrological_zone, ecoregion) %>%
    summarise(attributed_kg = sum(water_mass_kg, na.rm = TRUE), .groups = "drop") %>%
    collect() %>%
    left_join(coverage, by = "hydrological_zone") %>%
    mutate(attributed_kg = attributed_kg / coverage) %>%
    group_by(year, month, ecoregion) %>%
    summarise(attributed_m3 = sum(attributed_kg, na.rm = TRUE) / 1e3, .groups = "drop") %>%
    left_join(st_drop_geometry(ecoregions), by = "ecoregion") %>%
    left_join(observed, by = c("year", "month", "ecoregion")) %>%
    transmute(
      year, month, ecoregion, observed = evaporation,
      estimated = set_units(set_units(attributed_m3, "m3") / area, "mm"),
    ) %>%
    mutate(ratio = drop_units(estimated / observed))
}

compute_coverage <- function(config_file, mask_grid, aoi){
  mask_grid <- open_dataset(mask_grid) %>% collect()
  
  config_file %>% 
    read_json(simplifyVector = T) %>% 
    pluck("control", "points") %>% 
    distinct(lat, lon) %>%
    mutate(
      lon_idx = floor(lon * 100) %>% as.integer,
      lat_idx = floor(lat * 100) %>% as.integer
    ) %>%
    inner_join(mask_grid, by = c("lon_idx", "lat_idx"), copy = T) %>%
    count(hydrological_zone, name = "n_columns") %>%
    left_join(st_drop_geometry(aoi), by = "hydrological_zone") %>%
    mutate(
      area = set_units(area, "km2") %>% drop_units,
      sampled_area_km2 = n_columns * 900,
      coverage = sampled_area_km2 / area
    ) %>%
    select(hydrological_zone, coverage, sampled_area_km2)
}


metrics <- function(verification) {
  q <- function(x, p) quantile(x, p, na.rm = TRUE, names = FALSE)
  
  verification <- map(verification, \(x) {
    x <- ungroup(x)
    if ("config" %in% names(x)) x else mutate(x, config = "climatology")
  })
  
  metrics_pp <- verification$vs_pp_observed %>%
    filter(is.finite(ratio)) %>%
    group_by(config) %>%
    summarise(precip_mae = mean(abs(ratio - 1)),
              precip_bias = mean(ratio - 1), .groups = "drop")
  
  metrics_evap <- verification$vs_e_observed %>%
    filter(is.finite(ratio)) %>%
    group_by(config) %>%
    summarise(
      evap_excess = mean(pmax(ratio - 1, 0)),
      evap_exceed_frac = mean(ratio > 1), .groups = "drop",
      evap_max_ratio = max(ratio)
    )
  
  metrics_closure <- verification$closure %>%
    group_by(config) %>%
    summarise(
      closure_excess = mean(pmax(closure - 1, 0), na.rm = TRUE),
      closure_max = max(closure, na.rm = TRUE)
    ) %>%
    collect()
  
  metrics_attr <- verification$attribution %>%
    filter(is.finite(ratio)) %>%
    group_by(config) %>%
    summarise(attr = list(set_names(
      quantile(ratio, seq(0, 1, 0.25), names = FALSE),
      c("q00", "q25", "q50", "q75", "q100")))) %>%
    unnest_wider(attr, names_sep = "_")
  
  reduce(
    list(metrics_pp, metrics_evap, metrics_closure, metrics_attr),
    inner_join, by = "config"
  )
}

