pacman::p_load(dplyr, tidyr, sf)

setup <- function(
  aoi,
  start_date,
  end_date,
  duration,
  interval_traj,
  available_levels,
  vertical_levels,
  cellsize,
  profile,
  bbox,
  top_model,
  vertical_method,
  path
) {
  HEIGHTS <- height_levels(profile, vertical_levels)

  PRESSURE_LEVELS <- filter(
    profile,
    level %in% available_levels
  ) %>%
    pull(level) %>%
    unique() %>%
    as.character() %>%
    as.numeric()

  OUTPUT_VARS <- list("tm_sphu", "tm_relh", "tm_mixd", "tm_rain")
  PRES_VARS <- "specific_humidity"
  SFC_VARS <- c(
    "boundary_layer_height",
    "total_precipitation",
    "surface_pressure"
  )

  POINTS <- aoi %>%
    st_transform(3857) %>%
    st_make_grid(cellsize = cellsize, what = "centers") %>%
    st_as_sf() %>%
    st_transform(4326) %>%
    {
      .[aoi, ]
    } %>%
    mutate(
      lon = st_coordinates(.)[, 1],
      lat = st_coordinates(.)[, 2]
    ) %>%
    st_drop_geometry() %>%
    crossing(height = HEIGHTS)

  project_setup(
    path = path,
    date.start = start_date,
    date.end = end_date,
    duration = duration,
    bbox = bbox,
    points = POINTS,
    top.model = top_model,
    pres.levels = PRESSURE_LEVELS,
    vertical.method = vertical_method,
    interval.traj = interval_traj,
    output.vars = OUTPUT_VARS,
    pres.vars = PRES_VARS,
    sfc.vars = SFC_VARS
  )

  return(path)
}
