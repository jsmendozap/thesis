pacman::p_load(tidyverse, sf, stars, terra, arcgislayers, jsonlite, rnaturalearth, here)

load_aoi <- function(){
  url <- "https://data.hydrosheds.org/file/HydroBASINS/standard/hybas_sa_lev03_v1c.zip"
  
  amazonian <- st_read(paste0("/vsizip/vsicurl/", url)) %>%
    filter(HYBAS_ID == 6030007000) %>%
    st_make_valid() %>%
    st_geometry()

  col <- ne_countries() %>%
    select(name) %>%
    filter(name == "Colombia") %>%
    st_geometry()

  amazonian_col <- st_intersection(col, amazonian)
  amazonian_col
}

basins <- function(aoi) {
  st_read("https://www.datos.gov.co/resource/5kjg-nuda.geojson") %>%
    st_intersection(aoi) %>%
    group_by(nom_zh) %>%
    summarise()
}

get_mask <- function(config){
  url <- "https://services.arcgis.com/jIL9msH9OI208GCb/ArcGIS/rest/services/Ocean_and_Country_Polygon_Masks/FeatureServer/91"

  bbox <- read_json(config, simplifyVector = T)$area %>%
    {st_bbox(c(xmin = .[2], xmax = .[4],  ymax = .[1], ymin = .[3]))}

  land_ocean_mask <- arc_open(url) %>%
    arc_select(fields = "LAND_OR_OCEAN", filter_geom = bbox) %>%
    st_make_valid()

  rast(xmin = -80, xmax = 20, ymin = -35, ymax = 30, res = 0.25, crs = "EPSG:4326") %>%
        {rasterize(x = land_ocean_mask, y = ., field = "LAND_OR_OCEAN")} %>%
        as.data.frame(xy = TRUE) %>%
        mutate(lon_idx = as.integer(floor(x * 4)), lat_idx = as.integer(floor(y * 4))) %>%
        select(lon_idx, lat_idx, location = LAND_OR_OCEAN)
}

profile <- function(aoi){
  here("data", "pressure_levels.nc") %>%
    read_stars() %>%
    st_set_crs(4326) %>%
    .[aoi] %>%
    transmute(flux = q * sqrt(u^2 + v^2), q) %>%
    st_apply(c("level", "time"), mean, na.rm = TRUE) %>%
    as.data.frame() %>%
    as_tibble()
}
