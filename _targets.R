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
    name = raw_trajectories,
    command = dir(here("data", "raw"), full.names = T),
    description = "post_processing"
  ),
  tar_target(
    name = trajectories,
    command = process_trajectories(raw_trajectories),
    pattern = map(raw_trajectories),
    format = "file",
    description = "post-processing"
  ),
  tar_target(
    name = moisture_sources,
    command = identify_sources(trajectories),
    format = "parquet",
    description = "post-processing"
  )
)
