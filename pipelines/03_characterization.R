list(
    tar_target(
        name = trajectories,
        description = "HYSPLIT climatology files",
        command = dir_ls("~/project/simulation/output/", recurse = 1, glob = "*/month=*")
    ),
    tar_target(
        name = sources,
        description = "Sources identification in full climatology dataset",
        command = identify_sources(
            trajectories = trajectories, 
            qc = 0.3, 
            rh_arrival = 80,
            rh_loss = 0,
            rain_arrival = TRUE,
            path = here("output", "source"), 
            pressure_data = here("data", "single_levels.nc"),
            mask = land_ocean_mask, 
            threads = 8, 
            memory = 80
          ),
        pattern = map(trajectories),
        format = "file",
        garbage_collection = TRUE,
        resources = tar_resources(crew = tar_resources_crew(controller = "light"))
    ),
    tar_target(
      name = attribution, 
      description = "multi-annual main source ecoregions / TS source dataset", 
      command = source_attribution(
                  sources = sources, 
                  ecoregions = ecoregions,
                  pct = 90,
                  blh_limit = TRUE,
                  threads = 20,
                  memory = 120
                ),
      garbage_collection = TRUE
    ),
    tar_target(
      name = sources_hotspots,
      description = "Monthly time series of water supply per grid point",
      command = grid_source_depth(
        sources = sources,
        blh_limit = TRUE,
        path = here("output", "hotspots.parquet"),
        threads = 20, 
        memory = 120
      ),
      garbage_collection = TRUE,
      format = 'file'
    )
)
