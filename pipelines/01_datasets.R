list(
    tar_target(
        name = aoi,
        command = load_aoi()
    ),
    tar_target(
        name = sphu_profile,
        command = profile(aoi = aoi)
    ),
    tar_target(
        name = config_file,
        command = setup(
            aoi = aoi,
            start_date = "2025-12-31 23:00:00",
            end_date = "1995-01-01 00:00:00",
            duration = 360,
            interval_traj = 6,
            available_levels = 300:1000,
            vertical_levels = 50,
            cellsize = 40000,
            profile = sphu_profile,
            bbox = sf::st_bbox(c(xmin = -80, ymin = -35, xmax = 20, ymax = 30)),
            top_model = 9000,
            vertical_method = 0,
            path = here("hysplit", "config.json")
        ),
        format = "file",
        cue = tar_cue("never")
    ),
    tar_target(
        name = land_ocean_mask,
        command = get_mask(config_file, aoi, here("data", "mask_grid.parquet")),
        format = "file"
    ), 
    tar_target(
        name = monthly_precipitation,
        command = {
          data <- here("data", "precipitation_mm.nc")
          out <- here("data", "monthly_pp.parquet")
          get_monthly_pp(aoi, data, out)
        },
        format = "file"
    )
)
