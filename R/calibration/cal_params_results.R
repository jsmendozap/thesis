pacman::p_load(tidyverse, sf, arrow, units, jsonlite)

results_sod_config <- function(sources, cutoff, pp, evap, config_file, aoi, mask,
                               ecoregions, blh_limit) {
  
  config_dirs <- sources %>% dirname() %>% dirname() %>% unique()
  runs <- config_dirs %>%
    set_names(basename(config_dirs)) %>%
    map(open_dataset)
  
  coverage <- compute_coverage(config_file, mask, aoi)
  
  by_config <- \(fun) imap_dfr(runs, \(ds, config) {
    fun(ds) %>% mutate(config = config, .before = 1)
  })
  
  verification <- list(
    attribution = by_config(\(ds) check_attribution(ds, blh_limit)),
    closure = by_config(check_closure),
    vs_pp_observed = by_config(\(ds) check_vs_p_observed(ds, pp, coverage)),
    vs_e_observed  = by_config(\(ds) check_vs_e_observed(ds, evap, coverage,
                                                         ecoregions, blh_limit))
  )
  
  ecoregion_results <- lst(
    shares = ecoregion_shares(runs),
    variation = ecoregions_configs_var(shares, cutoff),
    corr = ecoregions_configs_corr(shares)
  )
  
  list(
    checks = verification,
    ecoregions = ecoregion_results,
    metrics = metrics(verification)
  )
}

ecoregion_shares <- function(runs){
  runs %>%
    imap_dfr(\(ds, config) {
      ds %>%
        filter(age != 0, !is.na(hydrological_zone)) %>%
        mutate(source_ecoregion = coalesce(ecoregion, country_or_ocean)) %>%
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

