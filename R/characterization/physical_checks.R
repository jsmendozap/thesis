pacman::p_load(duckspatial, here, DBI, arrow, duckdb)

checks_climatology <- function(sources, weights, pp, evap, config_file, aoi,
                               mask, ecoregions, blh_limit, memory, threads){
    
  con <- ddbs_create_conn(threads = threads, memory = memory)
  worker_tmp <- tempfile(pattern = "duckdb_", tmpdir = here("temp"))
  
  dbExecute(con, sprintf("SET temp_directory='%s';", worker_tmp))
  dbExecute(con, "SET preserve_insertion_order = false;")
  
  on.exit(
    {
      dbDisconnect(con, shutdown = TRUE)
      unlink(worker_tmp, recursive = TRUE)
      gc(full = T)
    },
    add = TRUE
  )
  
  ds <- sources %>% dirname %>% dirname %>% unique %>% open_dataset %>% to_duckdb(con = con)
  ds_corr <- repair_overlap(ds, weights, con)
  coverage <- compute_coverage(config_file, mask, aoi)
  
  verification <- list(
    attribution = check_attribution(ds, blh_limit),
    closure = check_closure(ds),
    vs_pp_observed = check_vs_p_observed(ds, pp, coverage),
    vs_e_observed  = check_vs_e_observed(ds, evap, coverage, ecoregions, blh_limit)
  )
  
  verification_corr <- list(
    attribution = check_attribution(ds_corr, blh_limit),
    closure = check_closure(ds_corr),
    vs_pp_observed = verification$vs_pp_observed,
    vs_e_observed  = check_vs_e_observed(ds_corr, evap, coverage, ecoregions, blh_limit)
  )
  
  list(
    checks = verification,
    checks_corr = verification_corr,
    metrics = metrics(verification),
    metrics_corr = metrics(verification_corr)
  )
}

repair_overlap <- function(ds, weights, con) {
  w <- weights %>% dirname() %>% dirname() %>% dirname() %>% unique() %>%
    open_dataset() %>% select(year, month, id, age, w_overlap)
  
  duckdb_register_arrow(con, name = "w_overlap_table", w)
  
  ds %>%
    left_join(tbl(con, "w_overlap_table"), by = join_by(year, month, id, age)) %>%
    mutate(w_overlap = coalesce(w_overlap, 1),
           water_mass_kg = water_mass_kg * w_overlap,
           fractional_contribution = fractional_contribution * w_overlap)
}