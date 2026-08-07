list(
    tar_target(
        name = vertical_profile_plots,
        command = vertical_exploration_plots(
            profile = sphu_profile,
            single_levels = here("data", "single_levels.nc"),
            aoi = aoi
        ),
        format = "file"
    ),
    tar_files(
        name = trajectories,
        command = dir(here("data", "trajectories"), full.names = TRUE)
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
            files <- grep(
                pattern = paste0("traj_", years),
                x = trajectories,
                value = TRUE
            )
            out_dir <- here("output", "source", paste0("year=", years))
            identify_sources(files, out_dir)
        },
        pattern = map(years),
        format = "file"
    )
)
