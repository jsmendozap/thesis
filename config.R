library(jsonlite)

project_setup <- function(path,
                          date.start,
                          date.end,
                          bbox,
                          points,
                          top.model,
                          vertical.method,
                          output.pres = "PRES",
                          output.sfc = "SFC",
                          pres.levels = c(seq(100, 250, 25), seq(300, 750, 50), seq(775, 1000, 25)),
                          pres.vars = NULL,
                          sfc.vars = NULL,
                          restart.interval = 0,
                          trajectory.duration = 9999,
                          output.vars = NULL) {
    if (!inherits(bbox, "bbox")) stop("bbox debe ser de clase 'bbox'")

    output <- c(
        "Potential Temperature", "Ambient Temperature", "Precipitation",
        "Mixing Depth", "Relative Humidity", "Specific Humidity",
        "Water Vapor Mix Ratio", "Solar Radiation", "Terrain Height",
        "U Wind", "V Wind"
    )

    if (!is.null(output.vars) && !all(output.vars %in% output)) {
        stop("Output variable not valid.")
    }

    if (!inherits(points, "data.frame") || dim(points)[2] != 3 || !all(c("lat", "lon", "height") %in% names(points))) {
        stop("Points must be a data.frame with columns: lat, lon, height.")
    }

    config <- list(
        date_start = date.start,
        date_end = date.end,
        area = c(bbox$ymax, bbox$xmin, bbox$ymin, bbox$xmax),
        datasets = list(
            pressure = list(
                name = "reanalysis-era5-pressure-levels",
                output = output.pres,
                pressure_levels = pres.levels,
                variables = c(
                    "geopotential",
                    "u_component_of_wind",
                    "v_component_of_wind",
                    "temperature",
                    "specific_humidity",
                    "vertical_velocity",
                    pres.vars
                ) |> unique()
            ),
            surface = list(
                name = "reanalysis-era5-single-levels",
                output = output.sfc,
                variables = c(
                    "surface_geopotential",
                    "10m_u_component_of_wind",
                    "10m_v_component_of_wind",
                    "2m_temperature",
                    sfc.vars
                ) |> unique()
            ),
            setup = list(
                restart_interval = restart.interval,
                trajectory_duration = trajectory.duration,
                vertical_method = vertical.method,
                top_model = top.model,
                points = points
            ),
            output = sapply(output, \(x) as.integer(x %in% output.vars)) |> as.list()
        )
    )

    write_json(x = config, path = path, pretty = T, auto_unbox = T)
}
