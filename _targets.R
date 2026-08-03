pacman::p_load(targets, tarchetypes, crew, here, jsonlite, tidyverse, fs)

tar_option_set(
  controller = crew_controller_local(workers = 2)
)

for (dir in dir_ls("R", type = "directory")) {
  tar_source(dir)
}

list(
  source(here("pipelines", "01_datasets.R")),
  source(here("pipelines", "02_calibration.R")),
  source(here("pipelines", "03_characterization.R"))
)
