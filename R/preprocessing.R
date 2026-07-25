pacman::p_load(tidyverse, sf, stars, rnaturalearth, here)

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
