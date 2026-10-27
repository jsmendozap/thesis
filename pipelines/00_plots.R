list(
  # Exploration 
  tar_target(
    name = vertical_profile_plots,
    command = vertical_exploration_plots(
      profile = sphu_profile,
      single_levels = here("data", "single_levels.nc"),
      aoi = aoi
    ),
    format = "file"
  ),
  tar_target(
    name = moisture_profile_plot,
    command = moisture_profile(sphu_profile),
    format = "file"
  ),
  # Calibration
  tar_target(
    name = duration_results,
    command = duration_plot(duration),
    format = "file"
  ),
  tar_target(
    name = config_plots,
    command = params_plots(config_results),
    format = "file"
  ),
  # Results
  tar_target(
    name = attr_plot,
    command = attribution_plot(attribution),
    format = 'file'
  ),
  tar_target(
    name = contour_plots, 
    command = grid_plots(sources_hotspots, sources)
  )
)