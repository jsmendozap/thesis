library(tidyverse)
library(jsonlite)
library(qgisprocess)
library(sf)

qgis <- qgis_project()

######### Study region #################

col <- rnaturalearth::ne_countries() %>%
    select(name) %>%
    filter(name == "Colombia") %>%
    st_geometry()

amazonian <- st_read("Amazonian.parquet") %>%
    st_make_valid() %>%
    st_geometry()

amazonian_col <- st_intersection(col, amazonian)
rm(col, amazonian)

######### Receptor points ################

qgis_get_argument_specs("native:randompointsinpolygons")

qgis_run_algorithm(
    "native:randompointsinpolygons",
    INPUT = st_sf(amazonian_col),
    POINTS_NUMBER = 500,
    MIN_DISTANCE = 0.25,
    SEED = 1,
    OUTPUT = "points.parquet"
)

points <- st_read("points.parquet")
qgis$insert_layer(points, "points")


######### Control file ################

points <- st_coordinates(points) %>%
    as_tibble() %>%
    crossing(alt = c(300, 500, 1500)) %>%
    select(lat = Y, long = X, alt)

n <- nrow(points)

config <- fromJSON("config.json")
duration <- interval(ymd_hms(config$date_start), ymd_hms(config$date_end)) |> as.numeric() / 3600
start <- format(ymd_hms(config$date_start), "%y %m %d %H")

file <- "CONTROL"

# Initial date: YY MM DD HH
cat(paste0(start, "\n"), file = file)

# Total points
cat(n, "\n", file = file, append = TRUE)

# Locations
write.table(points,
    file = file, append = TRUE,
    col.names = FALSE, row.names = FALSE, quote = FALSE, sep = " "
)

# Duration (hours) - Negative (Backward) or Positive (Forward)
cat(paste0(duration, "\n"), file = file, append = TRUE)

# Vertical Motion Method [0-8]
cat(paste0(config$vertical_method, "\n"), file = file, append = TRUE)

# Top of the model (meters)
cat(paste0(config$model_height, "\n"), file = file, append = TRUE)

# Number of meteorological files
cat("<<NUM_MET>>\n", file = file, append = TRUE)

# Name of meteorological file
cat("<<MET_BLOCK>>\n", file = file, append = TRUE)

# Output path
cat("../../../output/\n", file = file, append = TRUE)

# Output filename
cat("trajectories\n", file = file, append = TRUE)
