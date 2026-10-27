pacman::p_load(geoarrow, arrow, sf, sfarrow, duckspatial, tidyverse, units, DBI)

grid_source_depth <- function(sources, blh_limit, path, threads, memory){
  con <- ddbs_create_conn(threads = threads, memory_limit_gb = memory)
  
  on.exit({
    dbDisconnect(con, shutdown = TRUE)
    gc(full = T)
  }, add = TRUE)
  
  blh_filter <- if (blh_limit) expr(blh_ratio <= 1.5) else TRUE
  
  grid <- st_bbox(c(xmin = -80, ymin = -35, xmax = 20, ymax = 30), crs = 4326) %>%
    st_transform(3857) %>%
    st_make_grid(cellsize = 30000) %>%
    st_sf(id = 1:length(.), geometry = .) %>%
    st_transform(crs = 4326) %>%
    mutate(area_km2 = st_area(geometry) %>% set_units("km2"))
  
  ddbs_register_table(conn = con, data = grid, name = "grid", overwrite = T)
  
  result <- sources %>% dirname %>% dirname %>% unique %>% open_dataset() %>% 
    to_duckdb(con = con) %>%
    filter(!is.na(dest_hydrological_zone), !is.na(source_lon), water_mass_kg > 0, blh_filter) %>%
    mutate(geometry = ST_Point(source_lon, source_lat)) %>%
    select(id, geometry, water_mass_kg, year, month) %>%
    as_duckspatial_df(conn = con, crs = 4326) %>%
    ddbs_join(x = "grid", y = ., join = "intersects", conn = con) %>%
    group_by(id, year, month) %>%
    summarise(total_volume_km3 = sum(water_mass_kg, na.rm = TRUE) / 1e12, .groups = "drop") %>%
    collect()
  
  grid %>%
    inner_join(result, by = "id") %>%
    mutate(
      total_volume = set_units(total_volume_km3, "km3"),
      water_depth = set_units(total_volume / area_km2, "mm")
    ) %>%
    select(-area_km2) %>%
    st_write_parquet(path)
  
  return(path)
}