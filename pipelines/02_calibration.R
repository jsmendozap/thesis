list(
    tar_target(
        name = calibration_dir,
        command = dir_ls(
            path = here("data", "calibration"),
            type = "directory",
            recurse = TRUE,
            regexp = "\\d{4}/[^/]+"
        ), 
        deployment = "main"
    ),
    tar_target(
        name = calibration,
        command = {
            out_dir <- str_replace(calibration_dir, "data", "output")
            identify_sources(calibration_dir, out_dir, land_ocean_mask)
        },
        pattern = map(calibration_dir),
        format = "file",
        garbage_collection = TRUE,
        resources = tar_resources(crew = tar_resources_crew(controller = "light"))
    ),
    tar_target(
        name = duration,
        command = trajectory_duration(calibration),
        pattern = map(calibration),
        garbage_collection = TRUE
    ),
    tar_target(
        name = n_particles,
        command = grid_convergence(sphu_profile, calibration, monthly_precipitation),
        pattern = map(calibration),
        garbage_collection = TRUE,
        resources = tar_resources(crew = tar_resources_crew(controller = "light"))
    ),
    tar_target(
        name = parameters,
        command = simulation_parameters(
          duration = duration, 
          n_particles = n_particles, 
          duration_threshold = 0.01, 
          trj_threshold = 0.025
        )
    ),
    tar_target(
        name = calibration_results,
        command = calibration_plots(duration, n_particles, parameters),
        format = "file"
    ),
    tar_target(
        name = final_config,
        command = setup(
            aoi = aoi,
            start_date = "2025-12-31 23:00:00",
            end_date = "1995-01-01 00:00:00",
            duration = parameters$max_duration,
            interval_traj = 6,
            available_levels = 300:1000,
            vertical_levels = parameters$max_trajectories$n_levels,
            cellsize = parameters$max_trajectories$cellsize_km * 1000,
            profile = sphu_profile,
            bbox = sf::st_bbox(c(xmin = -80, ymin = -35, xmax = 20, ymax = 30)),
            top_model = 9000,
            vertical_method = 0,
            path = here("hysplit", "final_config.json")
          ),
        format = "file"
    )
)
