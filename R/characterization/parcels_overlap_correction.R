pacman::p_load(here, tidyverse, terra, sf, arrow, duckspatial, units, fs)

compute_overlap_weights <- function(sources, pressure_data, out_dir,
                                    threads, memory, max_back_days = 10) {
  
  con <- ddbs_create_conn(threads = threads, memory_limit_gb = memory)
  on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
  
  me <- parse_month_path(sources)
  current <- sprintf("%d%02d", me$year, me$month)
  out <- file.path(out_dir, sprintf("year=%d", me$year), sprintf("month=%02d", me$month), "weights.parquet")
  out %>% dirname %>% dir_create()
  
  pressure <- rast(pressure_data) %>% tidyterra::select(starts_with("sp_"))
  idx <- which(format(time(pressure), "%Y-%m") == sprintf("%d-%02d", me$year, me$month))
  sp_month <- mean(pressure[[idx]])

  column_frac <- sources %>%
    open_dataset() %>%
    filter(age == 0) %>% 
    distinct(lon = lon_t0, lat = lat_t0, air_col_mass_kg) %>% 
    collect() %>%
    mutate(
      column_ext = air_col_mass_kg * 9.8 / 9e8,
      pressure = terra::extract(sp_month, .[,1:2], ID = FALSE)[,1], 
      column_frac = column_ext/pressure
    ) %>%
    pull(column_frac) %>% 
    median(na.rm = TRUE)

  grid <- st_bbox(c(xmin = -80, ymin = -35, xmax = 20, ymax = 30), crs = 4326) %>%
    st_transform(3857) %>%
    st_make_grid(cellsize = 30000) %>%
    st_sf(cell_id = 1:length(.), geometry = .) %>%
    st_transform(crs = 4326) %>%
    mutate(
      area = st_area(geometry) %>% drop_units,
      pressure = terra::extract(sp_month, vect(st_centroid(geometry)), ID = F)[,1],
      air_col_mass_kg = area * column_frac * pressure / 9.8
    ) %>%
    select(cell_id, air_col_mass_kg)
  
  ddbs_register_table(conn = con, data = grid, name = "grid", overwrite = T)
  
  load_dataset(sources, max_back_days) %>%
    to_duckdb(con = con) %>%
    mutate(
      t_src = sql("strptime(substr(id, 1, 10), '%Y%m%d%H') + to_hours(CAST(age AS BIGINT))"),
      geometry = ST_Point(source_lon, source_lat),
    ) %>%
    as_duckspatial_df(conn = con, crs = 4326) %>%
    ddbs_join(y = "grid", join = "within", conn = con) %>%
    group_by(t_src, cell_id) %>%
    mutate(w_overlap = coalesce(pmin(1, air_col_mass_kg / sum(parcel_mass_kg, na.rm = TRUE)), 1)) %>%
    ungroup() %>%
    filter(str_sub(id, 1, 6) == !!current) %>%
    select(id, age, w_overlap) %>%
    ddbs_write_dataset(path = out, overwrite = TRUE)
  
  return(out)
}

parse_month_path <- function(p) {
  m <- str_match(p, "^(.*)/year=([0-9]{4})/month=([0-9]{2})")
  tibble(root = m[, 2], year = as.integer(m[, 3]), month = as.integer(m[, 4]))
}

load_dataset <- function(sources, max_back_days = 10) {
  current <- parse_month_path(sources)
  month_start <- as.Date(sprintf("%d-%02d-01", current$year, current$month))
  window <- c(seq(month_start, by = "-1 month", length.out = 2)[2],
                   month_start,
                   seq(month_start, by = "month", length.out = 2)[2])
  
  available <- sources %>% dirname() %>% dirname() %>% 
    dir_ls(type = "directory", recurse = TRUE, glob = "*/month=*") %>%
    parse_month_path() %>% 
    mutate(date = as.Date(sprintf("%d-%02d-01", year, month)))
  
  months <- window[window %in% available$date]
  dirs   <- file.path(current$root, format(months, "year=%Y"), format(months, "month=%m"))
  
  from <- format(month_start - max_back_days, "%Y%m%d00")
  to   <- format(window[3] + max_back_days, "%Y%m%d00")
  
  open_dataset(map(dirs, open_dataset)) %>%
    filter(age < 0, substr(id, 1, 10) >= from, substr(id, 1, 10) < to) %>%
    select(id, age, parcel_mass_kg, source_lon, source_lat)
}
