pacman::p_load(targets, tarchetypes, crew, here, jsonlite, tidyverse, fs)

tar_option_set(
  controller = crew_controller_group(
    crew_controller_local(
      name = "heavy",
      workers = 1,
      seconds_idle = 60,       
      tasks_max = 1
    ),
    crew_controller_local(
      name = "light",
      workers = 2
    ),
    crew_controller_local(
      name = "ultralight",
      workers = 5
    )
  ),
  storage = "worker", 
  retrieval = "worker",
  memory = "transient"
)

for (dir in dir_ls("R", type = "directory")) {
  tar_source(dir)
}

list(
  source(here("pipelines", "01_datasets.R")),
  source(here("pipelines", "02_calibration.R")),
  source(here("pipelines", "03_characterization.R")),
  source(here("pipelines", "00_plots.R"))
)
