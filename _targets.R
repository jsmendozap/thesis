pacman::p_load(targets, tarchetypes, crew, here, jsonlite, tidyverse, fs)

tar_option_set(
  controller = crew_controller_local(workers = 2)
)

# Loading functions of R folder
tar_source()

# Steps of the workflow
list(
  tar_target(
    name = aoi,
    command = load_aoi(),
    description = "pre-processing"
  ),
  tar_target(
    name = hydrological_zones, 
    command = basins(aoi),
    description = "pre-processing"
  ),
  tar_target(
    name = sphu_profile,
    command = profile(aoi = aoi),
    description = "exploration"
  ),
  tar_target(
    name = moisture_profile_plot,
    command = moisture_profile(sphu_profile),
    description = "exploration",
    format = "file"
  ),
  tar_target(
    name = calibration_dir,
    command = dir_ls(
      path = here("data", "calibration"), 
      type = "directory",
      recurse = T, 
      regexp = "\\d{4}/[^/]+/\\d+"
    ),
    description = "calibration"
  ),
  tar_target(
    name = calibration, 
    command = {
      files <- dir_ls(calibration_dir, type = 'file', glob = "*.parquet")
      parts <- strsplit(as.character(calibration_dir), "/")[[1]]
      n <- length(parts)

      out_dir <- here("output", "calibration", 
                      paste0("year=", parts[n - 2]), 
                      paste0("month=", parts[n - 1]), 
                      paste0("duration=", parts[n]))

      identify_sources(files, out_dir)
    },
    pattern = map(calibration_dir),
    format = "file",
    description = "calibration"
  ),
  tar_target(
    name = config_file,
    command = setup(
      profile = sphu_profile, aoi = aoi,
      path = here("hysplit", "config.json")
    ),
    format = "file",
    description = "pre-processing"
  ),
  tar_files(
    name = trajectories,
    command = dir(here("data", "trajectories"), full.names = T),
    description = "post_processing"
  ),
  tar_target(
    name = years, 
    command = {
      #start <- read_json(config_file)$date_start |> year()
      #end <- read_json(config_file)$date_end |> year()
      #start:end
      1995:1996
    }, 
    description = "post-processing"
  ),
  tar_target(
    name = moisture_sources,
    command = {
      files <- grep(pattern = paste0("traj_", years), x = trajectories, value = TRUE)
      out_dir <- here("output", "source", paste0("year=", years))
      identify_sources(files_per_year, out_dir)
    },
    pattern = map(years),
    format = "file",
    description = "post-processing"
  )
)
