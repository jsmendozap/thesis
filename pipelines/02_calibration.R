list(
    tar_target(
        name = calibration_dir,
        description = "List calibration trajectories files",
        command = dir_ls(
            path = here("data", "calibration"),
            type = "directory",
            recurse = TRUE,
            regexp = "\\d{4}/[^/]+"
        ), 
        deployment = "main"
    ),
    tar_target(
      name = cal_duration,
      description = "Execution of Sodemann moisture diagnostic on calibration dataset",
      command = {
        identify_sources(
          trajectories = calibration_dir, 
          qc = 0.3, 
          rh_arrival = 80,
          rh_loss = 0,
          rain_arrival = TRUE,
          path = str_replace(calibration_dir, "data", "output"),
          pressure_data = file.path("data", "single_levels.nc"),
          mask = land_ocean_mask,
          memory = 80, 
          threads = 5
        )
      },
      pattern = map(calibration_dir),
      format = "file",
      garbage_collection = TRUE,
      resources = tar_resources(crew = tar_resources_crew(controller = "light"))
    ),
    tar_target(
      name = duration,
      description = "Calculate duration-based unknown origins",
      command = trajectory_duration(cal_duration),
      pattern = map(cal_duration),
      garbage_collection = TRUE,
      resources = tar_resources(crew = tar_resources_crew(controller = "light"))
    ),
    tar_target(
      name = trj_duration,
      command = {
        duration %>%
          arrange(year, month, durations) %>%
          group_by(year, month) %>%
          mutate(marginal_gain = lag(unknown_origin) - unknown_origin) %>%
          filter(marginal_gain < 0.025) %>%
          slice_head(n = 1) %>%
          ungroup() %>%
          pull(durations) %>%
          max()
      }
    ),
    tar_target(
      name = calibration_config,
      description = "Definition of Sodemann parameter combinations",
      command = {
        patterns <- expand_grid(
          year = c(2000, 2014, 2015),
          month = c("03", "05", "08")
        ) %>%
        mutate(pattern = str_glue("year={year}/month={month}")) %>%
        pull(pattern) %>%
        str_flatten(collapse = "|")
        
        base_config <- tribble(
          ~rain_arrival, ~rh_arrival, ~rh_loss,
          FALSE,         80,          80,
          TRUE,          80,          0,
        )
        
        expand_grid(
          trj = str_subset(trajectories, patterns),
          qc = 0.3,
          base_config
        ) %>%
          mutate(
            config = sprintf("rain=%s_arrival=%d_loss=%d_qc=%.1f",
                             rain_arrival, rh_arrival, rh_loss, qc)
          )
      }
    ),
    tar_target(
      name = algorithm_parameters,
      description = "Calibration of Sodemann parameters",
      command = {
        identify_sources(
          trajectories = calibration_config$trj, 
          qc = calibration_config$qc, 
          rh_arrival = calibration_config$rh_arrival,
          rh_loss = calibration_config$rh_loss,
          rain_arrival = calibration_config$rain_arrival,
          path = file.path("output", "sodemann_parameters", calibration_config$config),
          pressure_data = file.path("data", "single_levels.nc"),
          mask = land_ocean_mask,
          memory = 80, 
          threads = 12
        )
      },
      pattern = map(calibration_config),
      format = "file",
      garbage_collection = TRUE,
      resources = tar_resources(crew = tar_resources_crew(controller = "light"))
    ),
    tar_target(
      name = config_results,
      description = "Benchmark Sodemann sensitivity and attribution metrics",
      command = results_sod_config(
        sources = algorithm_parameters,
        cutoff = 90,
        pp = monthly_precipitation,
        evap = monthly_evaporation, 
        config_file = config_file,
        aoi = aoi,
        mask = land_ocean_mask,
        ecoregions = ecoregions,
        blh_limit = FALSE
      ) 
    )
)
