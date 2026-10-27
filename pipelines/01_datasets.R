list(
    tar_target(
        name = aoi,
        description = "Load Amazon hydrological zones dataset",
        command = load_aoi()
    ),
    tar_target(
        name = sphu_profile,
        description = "Water/wind vertical profile time series extraction",
        command = profile(aoi = aoi)
    ),
    tar_target(
        name = config_file,
        description = "Creation of HYSPLIT config file",
        command = setup(
            aoi = aoi,
            start_date = "2025-12-31 23:00:00",
            end_date = "1995-01-01 00:00:00",
            duration = 240,
            interval_traj = 6,
            pressure_levels = 300:1000,
            height_levels = 350:1000,
            cellsize = 30000,
            profile = sphu_profile,
            bbox = sf::st_bbox(c(xmin = -80, ymin = -35, xmax = 20, ymax = 30)),
            top_model = 9000,
            vertical_method = 0,
            path = here("hysplit", "config.json")
        ),
        format = "file"
    ),
    tar_target(
      name = ecoregions,
      description = "Load ecoregions dataset",
      command = load_ecoregions(config_file)
    ),
    tar_target(
        name = land_ocean_mask,
        description = "Build land-ocean spatial mask",
        command = get_mask(config_file, aoi, ecoregions, here("data", "mask_grid.parquet")),
        format = "file"
    ), 
    tar_target(
        name = monthly_precipitation,
        description = "Build monthly precipitation dataset",
        command = {
          data <- here("data", "precipitation_mm.nc")
          out <- here("data", "monthly_pp.parquet")
          get_monthly_pp(aoi, data, out)
        },
        format = "file"
    )
)
