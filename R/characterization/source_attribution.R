pacman::p_load(arrow, tidyverse, duckspatial, DBI, dbplyr, units)

source_attribution <- function(sources, ecoregions, pct, blh_limit, threads, memory) {
  con <- ddbs_create_conn(threads = threads, memory_limit_gb = memory)
  
  on.exit({
    dbDisconnect(con, shutdown = TRUE)
    gc()
  }, add = TRUE)
  
  blh_filter <- if (blh_limit) expr(blh_ratio <= 1.5) else TRUE
  
  areas_eco <- ecoregions %>% 
    select(ecoregion = ECO_NAME) %>%
    mutate(area_km2 = st_area(.) %>% set_units("km2")  %>% as.numeric) %>%
    st_drop_geometry()
  
  full_data <- sources %>% dirname() %>% dirname() %>% unique %>%
    open_dataset() %>%
    filter(!is.na(dest_hydrological_zone), !is.na(source_lat), !!blh_filter) %>%
    select(dest_hydrological_zone, ecoregion, water_mass_kg, year, month) %>%
    to_duckdb(con = con) %>%
    group_by(year, month, dest_hydrological_zone, ecoregion) %>%
    summarise(mass_kg = sum(water_mass_kg, na.rm = TRUE), .groups = "drop") %>%
    mutate(volume_km3 = mass_kg / 1e12) %>%
    select(-mass_kg) %>%
    complete(
      year, month, nesting(dest_hydrological_zone, ecoregion),
      fill = list(volume_km3 = 0)
    ) %>%
    collect()
   
  main_ecoregions <- full_data %>%
    group_by(dest_hydrological_zone, ecoregion, year) %>%
    summarise(volume_km3 = sum(volume_km3), .groups = "drop_last") %>%
    summarise(mean_volume_km3 = mean(volume_km3), .groups = "drop_last") %>%
    arrange(desc(mean_volume_km3), ecoregion, .by_group = T) %>%
    mutate(
      contribution_pct = 100 * mean_volume_km3 / sum(mean_volume_km3),
      cumulative_pct = cumsum(contribution_pct)
    ) %>%
    filter(lag(cumulative_pct, default = 0) < pct) %>%
    ungroup() %>%
    left_join(areas_eco, by = "ecoregion") %>%  
    mutate(supply_mm = mean_volume_km3 / area_km2 * 1e6) %>%
    select(-area_km2, -cumulative_pct)
  
  res <- list(
    ts = full_data %>%
      semi_join(main_ecoregions, by = c("dest_hydrological_zone", "ecoregion")),
    main_ecoregions = main_ecoregions
  )
  
  return(res)
}
