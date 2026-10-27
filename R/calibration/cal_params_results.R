pacman::p_load(tidyverse, sf, arrow, units, jsonlite)

results_sod_config <- function(algorithm_parameters, cutoff, monthly_precipitation,
                               config_file, aoi, land_ocean_mask){
  config_dirs <- algorithm_parameters %>% dirname() %>% dirname() %>% unique()
  runs <- config_dirs %>%
    set_names(basename(config_dirs)) %>%
    map(open_dataset) 
  
  # Checks
  
  verification <- list(
    attribution = imap_dfr(runs, \(ds, config) {
      check_attribution(ds) %>% mutate(config = config, .before = 1)
    }),
    closure = imap_dfr(runs, \(ds, config) {
      check_closure(ds) %>% mutate(config = config, .before = 1)
    }),
    vs_observed = imap_dfr(runs, \(ds, config) {
      check_vs_observed(ds, monthly_precipitation, config_file, aoi, land_ocean_mask) %>%
        mutate(config = config, .before = 1)
    })
  )
  
  # Variation of main ecoregions across configurations
  
  ecoregions <- lst(
    shares = ecoregion_shares(runs),
    variation = ecoregions_configs_var(shares, cutoff),
    corr = ecoregions_configs_corr(shares)
  )
  
  list(
    checks = verification,
    ecoregions = ecoregions,
    metrics = metrics(verification)
  )
  
}

check_attribution <- function(ds) {
  ds %>%
    group_by(year, month, dest_hydrological_zone) %>%
    summarise(precip_kg = sum(precipitation_kg),
              attributed_kg = sum(water_mass_kg),
              n_parcels = sum(if_else(age == 0, 1L, 0L)),
              n_sources = sum(if_else(age < 0, 1L, 0L)),
              .groups = 'drop') %>%
    collect() %>%
    mutate(ratio = attributed_kg / precip_kg)
}

check_closure <- function(ds) {
  ds %>%
    group_by(year, month, id) %>%
    summarise(closure = sum(fractional_contribution), .groups = "drop") %>%
    collect()
}

check_vs_observed <- function(ds, monthly_precipitation, config_file, aoi, land_ocean_mask) {
  
  observed <- monthly_precipitation %>%
    open_dataset() %>%
    mutate(year = as.integer(year), month = as.integer(month)) %>%
    rename(dest_hydrological_zone = hydrological_zone) %>%
    collect()
  
  mask_grid <- land_ocean_mask %>% 
    open_dataset() %>% 
    select(dest_hydrological_zone = hydrological_zone, lon_idx, lat_idx)
  
  area <- aoi %>%
    mutate(area_km2 = st_area(.) %>% set_units('km2') %>% as.numeric) %>%
    st_drop_geometry() %>%
    rename(dest_hydrological_zone = nom_zh)
  
  coverage <- config_file %>% 
    read_json(simplifyVector = T) %>% 
    pluck("control", "points") %>% 
    distinct(lat, lon) %>%
    mutate(
      lon_idx = floor(lon * 100) %>% as.integer,
      lat_idx = floor(lat * 100) %>% as.integer
    ) %>%
    inner_join(mask_grid, by = c("lon_idx", "lat_idx"), copy = T) %>%
    count(dest_hydrological_zone, name = "n_columns") %>%
    left_join(area, by = "dest_hydrological_zone") %>%
    mutate(coverage = n_columns * 900 / area_km2) %>%
    select(dest_hydrological_zone, coverage)
  
  ds %>%
    filter(age == 0) %>%
    group_by(year, month, dest_hydrological_zone) %>%
    summarise(p_la_km3 = sum(precipitation_kg) / 1e12) %>%
    collect() %>%
    left_join(observed, by = c("year", "month", "dest_hydrological_zone")) %>%
    left_join(coverage, by = "dest_hydrological_zone") %>%
    mutate(ratio = p_la_km3 / (precipitation_km3 * coverage)) %>%
    ungroup()
}

metrics <- function(verification) {
  metrics_obs <- verification$vs_observed %>%
    drop_na(dest_hydrological_zone, precipitation_km3) %>%
    group_by(config) %>%
    summarise(precip_mae  = mean(abs(ratio - 1)), .groups = "drop")
  
  metrics_closure <- verification$closure %>%
    ungroup() %>%
    group_by(config) %>%
    summarise(closure_excess = mean(pmax(closure - 1, 0)),
              .groups = "drop")
  
  metrics_attr <- verification$attribution %>%
    drop_na(dest_hydrological_zone) %>%
    group_by(config) %>%
    summarise(
      attr_mae = mean(abs(ratio - 1)),
      attr_min = min(ratio),
      attr_max = max(ratio),
      .groups = "drop"
      )
  
  metrics_obs %>%
    inner_join(metrics_closure, by = "config") %>%
    inner_join(metrics_attr, by = "config")
}

ecoregion_shares <- function(runs){
  runs %>%
    imap_dfr(\(ds, config) {
      ds %>%
        filter(age != 0) %>%
        mutate(source_ecoregion = coalesce(ecoregion, source_domain)) %>%
        group_by(year, month, source_ecoregion) %>%
        summarise(water_mass_kg = sum(water_mass_kg, na.rm = TRUE), .groups = "drop") %>%
        collect() %>%
        mutate(config = config)
    }) %>%
    mutate(year = as.integer(year), month = as.integer(month)) %>%
    group_by(config, year, month) %>%
    mutate(contribution_pct = 100 * water_mass_kg / sum(water_mass_kg)) %>%
    arrange(desc(contribution_pct), .by_group = TRUE) %>%
    mutate(cumulative_pct = cumsum(contribution_pct)) %>%
    ungroup()
}

ecoregions_configs_var <- function(ecoregion_shares, cutoff){
  
  main_ecoregions <- ecoregion_shares %>% 
    group_by(year, month, config) %>%
    filter(lag(cumulative_pct, default = 0) < cutoff) %>% 
    ungroup %>%
    distinct(source_ecoregion)
  
  ecoregion_shares %>%
    semi_join(main_ecoregions, by = "source_ecoregion") %>%
    group_by(config, source_ecoregion) %>%
    summarise(mean_pct = mean(contribution_pct),
              sd_periods = sd(contribution_pct),
              .groups = "drop") %>%
    group_by(source_ecoregion) %>%
    summarise(mean_across_configs = mean(mean_pct),
              min_pct = min(mean_pct),
              max_pct = max(mean_pct),
              range_pp = max_pct - min_pct,
              sd_between_periods = mean(sd_periods),
              periods_to_configs = sd_between_periods / range_pp,
              .groups = "drop") %>%
    arrange(desc(mean_across_configs))
}

ecoregions_configs_corr <- function(ecoregion_shares){
  ecoregion_shares %>%
    select(year, month, source_ecoregion, config, contribution_pct) %>%
    pivot_wider(
      names_from = config,
      values_from = contribution_pct
    ) %>%
    rename(Crespo_Otero = 4, Proposed = 5) %>%
    mutate(difference_pp = Proposed - Crespo_Otero) %>%
    group_by(year, month) %>%
    summarise(
      correlation = cor(
        Crespo_Otero,
        Proposed,
        use = "complete.obs",
        method = "spearman"
      ),
      .groups = "drop"
    ) 
}

