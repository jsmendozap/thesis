pacman::p_load(targets, tarchetypes, crew, here)

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
    name = profile,
    command = profile(aoi = aoi), ,
    description = "pre-processing"
  ),
  tar_target(
    name = config_file,
    command = setup(
      profile = profile, aoi = aoi,
      path = here("hysplit", "config.json")
    ),
    format = "file",
    description = "pre-processing"
  ),
  tar_files(
    name = raw_files,
    command = dir(here("data", "raw"), full.names = T)
  ),
  tar_target(
    name = tidy_files,
    command = process_trajectories(raw_files),
    pattern = map(raw_files),
    format = "file",
    description = "post-processing"
  ),
  tar_target(
    name = moisture_source,
    command = identify_sources(tidy_files),
    format = "file",
    description = "post-processing"
  )
)
