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
  st_read("https://www.datos.gov.co/resource/5kjg-nuda.geojson") %>%
    filter(nom_ah == "Amazonas") %>%
    group_by(nom_zh) %>%
    summarise() %>%
    st_make_valid()
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
    st_crop(bbox)
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
    rasterize(template, field = "ECO_NAME")

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
    select(nom_zh, geometry) %>%
    rasterize(template, field = "nom_zh")

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

      source_domain = case_when(
        is_ocean ~ country_or_ocean,
        !is.na(ecoregion) ~ paste(country_or_ocean, ecoregion, sep = " - "),
        TRUE ~ paste(country_or_ocean, "Unclassified Ecoregion", sep = " - ")
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
      hydrological_zone,
      source_domain
    ) %>%
    write_parquet(path, compression = "ZSTD")

  return(path)
}


get_monthly_pp <- function(aoi, file, path) {
  template <- rast(ext(st_bbox(aoi)), res = 0.01, crs = "EPSG:4326")
  
  data <- rast(file)
  dates <- time(data) %>% format("%Y_%m")
  
  data_monthly <- tapp(data, index = dates, fun = sum, na.rm = TRUE) %>% 
    resample(template, method = "near")
  names(data_monthly) <- unique(dates)
  crs(data_monthly) <- "EPSG:4326"
  
  data_monthly %>%
    # Computing cellsize and performing conversion from mm to km3
    # 1 mm = 1e-6 km. Volume = Area (km2) * Depth (km)
    {cellSize(., unit = "km") * data_monthly * 1e-6}   %T>%
    {names(.) <- names(data_monthly)} %>%
    # Extracting volume by basin
    exact_extract(st_as_sf(aoi), 'sum') %>%
    mutate(hydrological_zone = aoi$nom_zh) %>%
    pivot_longer(
      cols = starts_with("sum."),
      names_to = "layer_name",
      values_to = "precipitation_km3"
    ) %>%
    mutate(
      year = str_extract(layer_name, "[0-9]{4}"),
      month = str_extract(layer_name, "(?<=[0-9]{4}_)[0-9]{2}")
    ) %>%
    select(year, month, hydrological_zone, precipitation_km3) %>%
    write_parquet(path, compression = "ZSTD")
  
  return(path)
}


profile <- function(aoi) {
  here("data", "pressure_levels.nc") %>%
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
