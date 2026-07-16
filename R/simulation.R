pacman::p_load(dplyr, tidyr, sf)

setup <- function(profile, aoi, path) {
  START_DATE <- "2025-12-31 23:00:00"
  END_DATE <- "1995-01-01 00:00:00"
  DURATION <- 168
  N <- 100

  HEIGHTS <- profile %>%
    group_by(level) %>%
    summarise(flux = mean(flux)) %>%
    arrange(desc(level)) %>%
    mutate(flux_cum = cumsum(flux) / sum(flux)) %>%
    {approxfun(.$flux_cum, .$level)} %>%
    {.(seq(0.05, 0.99, length.out = 30))} %>%
    {8000 * log(1014 / .)} %>%
    round(digits = -1)

  CONFIG_PATH <- path
  BBOX <- st_bbox(c(xmin = -80, ymin = -35, xmax = 20, ymax = 30))
  TOP_MODEL <- 9000
  PRESSURE_LEVELS <- filter(profile, level >= units::as_units("300 millibars")) %>%
    pull(level) %>%
    unique() %>%
    as.numeric()
  VERTICAL_METHOD <- 0
  INTERVAL_TRAJ <- 6
  OUTPUT_VARS <- list("tm_sphu", "tm_relh", "tm_mixd", "tm_rain")
  PRES_VARS <- "specific_humidity"
  SFC_VARS <- c("boundary_layer_height", "total_precipitation", "surface_pressure")

  POINTS <- st_sample(x = aoi, type = "random", size = N) %>%
    st_coordinates() %>%
    as.data.frame() %>%
    crossing(height = HEIGHTS) %>%
    select(lat = Y, lon = X, height)

  project_setup(
    path = CONFIG_PATH,
    date.start = START_DATE,
    date.end = END_DATE,
    duration = DURATION,
    bbox = BBOX,
    points = POINTS,
    top.model = TOP_MODEL,
    pres.levels = PRESSURE_LEVELS,
    vertical.method = VERTICAL_METHOD,
    interval.traj = INTERVAL_TRAJ,
    output.vars = OUTPUT_VARS,
    pres.vars = PRES_VARS,
    sfc.vars = SFC_VARS
  )

  return(path)
}
