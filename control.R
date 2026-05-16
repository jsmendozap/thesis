library(tidyverse)
library(jsonlite)
library(qgisprocess)
library(sf)

qgis <- qgis_project()

######### Study region ###################

url <- "https://data.hydrosheds.org/file/HydroBASINS/standard/hybas_sa_lev03_v1c.zip"
amazonian <- st_read(paste0("/vsizip/vsicurl/", url)) %>% 
  filter(HYBAS_ID == 6030007000) %>%
  st_make_valid() %>%
  st_geometry()

col <- rnaturalearth::ne_countries() %>%
    select(name) %>%
    filter(name == "Colombia") %>%
    st_geometry()

amazonian_col <- st_intersection(col, amazonian)
rm(col, amazonian)

######### Receptor points ################

qgis_get_argument_specs("native:randompointsinpolygons")

path <- qgis_run_algorithm(
    "native:randompointsinpolygons",
    INPUT = st_sf(amazonian_col),
    POINTS_NUMBER = 500,
    MIN_DISTANCE = 0.25,
    SEED = 1
  )$OUTPUT

config <- fromJSON("config.json")
config$control$points <- st_read(path) %>%
  st_coordinates() %>%
    as.data.frame() %>%
    crossing(height = c(300, 500, 1500)) %>%
    select(lat = Y, long = X, height)

toJSON(config, auto_unbox = T, pretty = T) %>%
  write(file = "config.json")

qgis_clean_tmp()
