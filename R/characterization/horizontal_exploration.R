pacman::p_load(geoarrow, arrow, sf, sfarrow, duckspatial, tidyverse, units, DBI, here)

grid_source_depth <- function(sources, weights, blh_limit, path, threads, memory){
  con <- ddbs_create_conn(threads = threads, memory_limit_gb = memory)
  worker_tmp <- tempfile(pattern = "duckdb_", tmpdir = here("temp"))
  
  dbExecute(con, sprintf("SET temp_directory='%s';", worker_tmp))
  dbExecute(con, "SET preserve_insertion_order = false;")
  
  on.exit({
    dbDisconnect(con, shutdown = TRUE)
    unlink(worker_tmp, recursive = TRUE)
    gc(full = T)
  }, add = TRUE)
  
  blh_filter <- if (blh_limit) expr(blh_ratio <= 1.5) else TRUE
  
  grid <- st_bbox(c(xmin = -80, ymin = -35, xmax = 20, ymax = 30), crs = 4326) %>%
    st_transform(3857) %>%
    st_make_grid(cellsize = 30000) %>%
    st_sf(cell_id = 1:length(.), geometry = .) %>%
    st_transform(crs = 4326) %>%
    mutate(area_km2 = st_area(geometry) %>% set_units("km2"))
  
  ddbs_register_table(conn = con, data = grid, name = "grid", overwrite = T)
  
  overlap_weights <- weights %>%
    dirname %>% dirname %>% dirname %>% unique %>%
    open_dataset() %>%
    to_duckdb(con = con)
  
  result <- sources %>% dirname %>% dirname %>% unique %>% open_dataset() %>% 
    to_duckdb(con = con) %>%
    filter(!is.na(hydrological_zone), !is.na(source_lon), water_mass_kg > 0, !!blh_filter) %>%
    left_join(overlap_weights, by = join_by(year, month, id, age)) %>%
    mutate(
      water_mass_corr_kg = water_mass_kg * coalesce(w_overlap, 1),
      geometry = ST_GeomFromWKB(geometry)
    ) %>%
    select(geometry, water_mass_kg, water_mass_corr_kg, year, month) %>%
    as_duckspatial_df(conn = con, crs = 4326) %>%
    ddbs_join(x = "grid", y = ., join = "intersects", conn = con) %>%
    group_by(cell_id, year, month) %>%
    summarise(
      total_volume_km3 = sum(water_mass_kg, na.rm = TRUE) / 1e12,
      total_volume_corr_km3 = sum(water_mass_corr_kg, na.rm = TRUE) / 1e12,
      .groups = "drop"
    ) %>%
    collect()
  
  grid %>%
    inner_join(result, by = "cell_id") %>%
    mutate(
      total_volume = set_units(total_volume_km3, "km3"),
      total_volume_corr = set_units(total_volume_corr_km3, "km3"),
      water_depth = set_units(total_volume / area_km2, "mm"),
      water_depth_corr = set_units(total_volume_corr / area_km2, "mm")
    ) %>%
    select(-area_km2) %>%
    st_write_parquet(path)
  
  return(path)
}