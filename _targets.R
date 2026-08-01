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
    command = load_aoi()
  ),
  tar_target(
    name = hydrological_zones, 
    command = basins(aoi)
  ),
  tar_target(
    name = sphu_profile,
    command = profile(aoi = aoi)
  ),
  tar_target(
    name = moisture_profile_plot,
    command = moisture_profile(sphu_profile),
    format = "file"
  ),
  tar_target(
    name = config_file,
    command = setup(
      profile = sphu_profile, aoi = aoi,
      path = here("hysplit", "config.json")
    ),
    format = "file",
    cue = tar_cue(mode = "never")
  ),
  tar_target(
    name = land_ocean_mask,
    command = get_mask(config_file)
  ),
  tar_target(
    name = calibration_dir,
    command = dir_ls(
      path = here("data", "calibration"), 
      type = "directory",
      recurse = T, 
      regexp = "\\d{4}/[^/]+"
    )
  ),
  tar_target(
    name = calibration, 
    command = {
      files <- dir_ls(calibration_dir, type = 'file', glob = "*.parquet")
      out_dir <- str_replace(calibration_dir, "data", "output")
      identify_sources(files, out_dir, land_ocean_mask)
    },
    pattern = map(calibration_dir),
    format = "file"
  ),
  tar_target(
    name = duration, 
    command = trajectory_duration(calibration),
    pattern = map(calibration)
  ),
  tar_target(
    name = points, 
    command = trajectory_points(calibration),
    pattern = map(calibration),
  ),
  tar_target(
    name = results_calibration,
    command = calibration_plots(duration, points),
    format = "file"
  ),
  tar_target(
    name = final_config, 
    command = {
      config <- read_json(here("hysplit", "config.json"), simplifyVector = T)
      params <- simulation_parameters(duration, points)

      config$control$points <- config %>%
        pluck("control", "points") %>%
        group_by(height) %>%
        slice_sample(n = params$max_trajectories/30)

      config$duration <- params$max_duration
      write_json(config, here("hysplit", "simulation_config.json"), pretty = T, auto_unbox = T)
    }, 
    format = "file",
    cue = tar_cue(mode = "never")
  ),
  tar_files(
    name = trajectories,
    command = dir(here("data", "trajectories"), full.names = T)
  ),
  tar_target(
    name = years, 
    command = {
      #start <- read_json(config_file)$date_start |> year()
      #end <- read_json(config_file)$date_end |> year()
      #start:end
      1995:1996
    }
  ),
  tar_target(
    name = moisture_sources,
    command = {
      files <- grep(pattern = paste0("traj_", years), x = trajectories, value = TRUE)
      out_dir <- here("output", "source", paste0("year=", years))
      identify_sources(files, out_dir)
    },
    pattern = map(years),
    format = "file"
  )
)
