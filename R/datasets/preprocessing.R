pacman::p_load(
  'tidyverse',
  'sf',
  'stars',
  'terra',
  'jsonlite',
  'rnaturalearth',
  'here',
  'nanoparquet'
)

load_aoi <- function() {
  col <- ne_countries(country = "Colombia", returnclass = "sf") %>%
    st_geometry()

  url <- "https://data.hydrosheds.org/file/HydroBASINS/standard/hybas_sa_lev03_v1c.zip"

  st_read(
    paste0("/vsizip/vsicurl/", url),
    query = "SELECT * FROM hybas_sa_lev03_v1c WHERE HYBAS_ID = 6030007000"
  ) %>%
    st_make_valid() %>%
    st_geometry() %>%
    st_intersection(col)
}

basins <- function(aoi) {
  st_read("https://www.datos.gov.co/resource/5kjg-nuda.geojson") %>%
    st_intersection(aoi) %>%
    group_by(nom_zh) %>%
    summarise()
}

get_mask <- function(config, aoi, path) {
  bbox <- read_json(config, simplifyVector = T)$area %>%
    {
      st_bbox(c(xmin = .[2], xmax = .[4], ymax = .[1], ymin = .[3]))
    }

  wkt <- st_as_sfc(bbox) %>% st_as_text()
  template <- rast(ext(bbox), res = 0.01, crs = "EPSG:4326")

  countries <- ne_countries(scale = 10) %>%
    st_make_valid() %>%
    st_crop(bbox) %>%
    rasterize(template, field = "sovereignt")

  names(countries) <- "country"

  url <- "https://storage.googleapis.com/teow2016/Ecoregions2017.zip"
  ecoregions <- st_read(
    paste0("/vsizip/vsicurl/", url),
    wkt_filter = wkt,
    quiet = TRUE
  ) %>%
    st_make_valid() %>%
    st_crop(bbox) %>%
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
    st_as_sf() %>%
    rasterize(template)

  names(amazonian_col) <- "is_aoi"

  basins <- st_read("https://www.datos.gov.co/resource/5kjg-nuda.geojson") %>%
    st_intersection(aoi) %>%
    group_by(nom_zh) %>%
    summarise() %>%
    st_make_valid() %>%
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
        TRUE ~ paste0(country_or_ocean, "Unclassified Ecoregion", sep = " - ")
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
