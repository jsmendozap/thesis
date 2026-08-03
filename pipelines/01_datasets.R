list(
    tar_target(
        name = aoi,
        command = load_aoi()
    ),
    tar_target(
        name = hydrological_zones,
        command = basins(aoi)
    ),
    tar_target(
        name = sphu_profile,
        command = profile(aoi = aoi)
    ),
    tar_target(
        name = moisture_profile_plot,
        command = moisture_profile(sphu_profile),
        format = "file"
    ),
    tar_target(
        name = config_file,
        command = setup(
            profile = sphu_profile,
            aoi = aoi,
            path = here("hysplit", "config.json")
        ),
        format = "file",
        cue = tar_cue(mode = "never")
    ),
    tar_target(
        name = land_ocean_mask,
        command = get_mask(config_file)
    )
)
