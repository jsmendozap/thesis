pacman::p_load(targets, tarchetypes, crew, here, jsonlite, tidyverse)

tar_option_set(
  controller = crew_controller_local(workers = 4)
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
    name = sphu_profile,
    command = profile(aoi = aoi),
    description = "pre-processing"
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
    name = files_per_year,
    command = grep(pattern = paste0("traj_", years), x = trajectories, value = T),
    pattern = map(years), 
    description = "post-processing"
  ),
  tar_target(
    name = moisture_sources,
    command = identify_sources(files_per_year),
    pattern = map(files_per_year),
    format = "file",
    description = "post-processing"
  )
)
