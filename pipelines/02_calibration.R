list(
    tar_target(
        name = calibration_dir,
        command = dir_ls(
            path = here("data", "calibration"),
            type = "directory",
            recurse = TRUE,
            regexp = "\\d{4}/[^/]+"
        )
    ),
    tar_target(
        name = calibration,
        command = {
            out_dir <- str_replace(calibration_dir, "data", "output")
            identify_sources(calibration_dir, out_dir, land_ocean_mask)
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
        name = n_particles,
        command = grid_convergence(sphu_profile, calibration, config_file),
        pattern = map(calibration)
    ),
    tar_target(
        name = points,
        command = trajectory_points(calibration),
        pattern = map(calibration)
    ),
    tar_target(
        name = results_calibration,
        command = calibration_plots(duration, points),
        format = "file"
    ),
    tar_target(
        name = final_config,
        command = {
            config <- read_json(
                here("hysplit", "config.json"),
                simplifyVector = TRUE
            )
            params <- simulation_parameters(duration, points)

            config$control$points <- config %>%
                pluck("control", "points") %>%
                group_by(height) %>%
                slice_sample(n = params$max_trajectories / 30)

            config$duration <- params$max_duration
            write_json(
                config,
                here("hysplit", "simulation_config.json"),
                pretty = TRUE,
                auto_unbox = TRUE
            )
        },
        format = "file",
        cue = tar_cue(mode = "never")
    )
)
