pacman::p_load(
  'tidyverse',
  'magrittr',
  'sf',
  'stars',
  'terra',
  'jsonlite',
  'rnaturalearth',
  'here',
  'nanoparquet',
  'DBI',
  'duckdb',
  'dbplyr',
  'exactextractr'
)

load_aoi <- function() {
  # Napo is excluded due to its minimal area and the absence of trajectory 
  # inside its boundaries
  
  st_read("https://www.datos.gov.co/resource/5kjg-nuda.geojson") %>%
    filter(nom_ah == "Amazonas") %>%
    group_by(nom_zh) %>%
    summarise() %>%
    st_make_valid() %>% 
    mutate(area = st_area(.)) %>%
    filter(area > set_units(500e6, "m2")) %>%
    select(hydrological_zone = nom_zh, area)
}

load_ecoregions <- function(config){
  bbox <- read_json(config, simplifyVector = T)$area %>%
    {st_bbox(c(xmin = .[2], xmax = .[4], ymax = .[1], ymin = .[3]))}
  
  wkt <- st_as_sfc(bbox) %>% st_as_text()
  
  url <- "https://storage.googleapis.com/teow2016/Ecoregions2017.zip"
  ecoregions <- st_read(
    paste0("/vsizip/vsicurl/", url),
    wkt_filter = wkt,
    quiet = TRUE
  ) %>%
    st_make_valid() %>%
    st_crop(bbox) %>%
    select(ecoregion = ECO_NAME) %>%
    mutate(area = st_area(.))
}

get_mask <- function(config, aoi, ecoreg, path) {
  bbox <- read_json(config, simplifyVector = T)$area %>%
    {st_bbox(c(xmin = .[2], xmax = .[4], ymax = .[1], ymin = .[3]))}

  template <- rast(ext(bbox), res = 0.01, crs = "EPSG:4326")

  countries <- ne_countries(scale = 10) %>%
    st_make_valid() %>%
    st_crop(bbox) %>%
    rasterize(template, field = "sovereignt")

  names(countries) <- "country"

   ecoregions <- ecoreg %>%
    rasterize(template, field = "ecoregion")

  names(ecoregions) <- "ecoregion"

  sf_use_s2(FALSE)
  oceans <- ne_download(
    scale = 10,
    type = "geography_marine_polys",
    category = "physical"
  ) %>%
    st_make_valid() %>%
    st_crop(bbox) %>%
    rasterize(template, field = "name")

  sf_use_s2(TRUE)
  names(oceans) <- "ocean"

  amazonian_col <- aoi %>%
    summarise() %>%
    rasterize(template)

  names(amazonian_col) <- "is_aoi"

  basins <- aoi %>%
    select(hydrological_zone, geometry) %>%
    rasterize(template, field = "hydrological_zone")

  names(basins) <- "hydrological_zone"

  c(countries, ecoregions, oceans, amazonian_col, basins) %>%
    as.data.frame(xy = TRUE) %>%
    mutate(
      lon_idx = as.integer(floor(x * 100)),
      lat_idx = as.integer(floor(y * 100)),

      is_ocean = is.na(country),
      country_or_ocean = case_when(
        is_ocean ~ coalesce(ocean, "Coastal Waters"),
        TRUE ~ country
      ),

      is_aoi = !is.na(is_aoi)
    ) %>%
    select(
      lon_idx,
      lat_idx,
      country_or_ocean,
      ecoregion,
      is_aoi,
      is_ocean,
      hydrological_zone
    ) %>%
    write_parquet(path, compression = "ZSTD")

  return(path)
}


get_monthly_pp <- function(file, aoi, path) {
  template <- rast(ext(st_bbox(aoi)), res = 0.01, crs = "EPSG:4326")
  
  data <- rast(file)
  dates <- time(data) %>% format("%Y_%m")
  
  data_monthly <- tapp(data, index = dates, fun = sum, na.rm = TRUE) %>% 
    resample(template, method = "near") 
  names(data_monthly) <- unique(dates)
  crs(data_monthly) <- "EPSG:4326"
  
  data_monthly %>%
    exact_extract(st_as_sf(aoi), 'mean', append_cols = "hydrological_zone") %>%
    pivot_longer(
      cols = starts_with("mean."),
      names_to = "layer_name",
      values_to = "precipitation"
    ) %>%
    mutate(
      year = str_extract(layer_name, "[0-9]{4}") %>% as.integer,
      month = str_extract(layer_name, "(?<=[0-9]{4}_)[0-9]{2}") %>% as.integer,
      precipitation = set_units(precipitation, "mm")
    ) %>%
    select(year, month, hydrological_zone, precipitation) %>%
    write_parquet(path, compression = "ZSTD")
  
  return(path)
}


get_monthly_evap <- function(file, ecoregions, path){
  # units: m/day (negative because the flux is upward)
  evaporation <- rast(file) %>% select(starts_with("e_"))
  days_month <- time(evaporation) %>% days_in_month() %>% as.numeric
  
  # Change of units to mm/month
  evaporation <- evaporation * -1000 * days_month
  dates <- tibble(date = time(evaporation)) %>%
    mutate(id = row_number() %>% as.character())
  
  evaporation %>%
    exact_extract(ecoregions, 'mean', append_cols = "ecoregion") %>%
    pivot_longer(
      cols = starts_with("mean"),
      names_to = "id",
      names_prefix = "mean.e_", 
      values_to = "evap"
    ) %>% 
    left_join(dates) %>%
    transmute( 
      year = year(date),
      month = month(date),
      ecoregion,
      evaporation = set_units(evap, "mm")
    ) %>%
    write_parquet(path, compression = "ZSTD")
  
  return(path)
}


profile <- function(aoi, file) {
  file %>%
    read_stars() %>%
    st_set_crs(4326) %>%
    .[aoi] %>%
    mutate(flux = q * sqrt(u^2 + v^2), q, w) %>%
    st_apply(c("level", "time"), mean, na.rm = TRUE) %>%
    as.data.frame() %>%
    mutate(
      level = as.numeric(level),
      level = factor(level, levels = sort(unique(level), decreasing = TRUE)),
      year = year(time),
      month = month(time, label = TRUE, abbr = TRUE)
    )
}
