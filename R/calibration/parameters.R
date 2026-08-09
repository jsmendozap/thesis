pacman::p_load(tidyverse, zoo)

simulation_parameters <- function(duration, points) {
    max_duration <- duration %>%
        arrange(year, month, durations) %>%
        group_by(year, month) %>%
        mutate(marginal_gain = lag(unknown_origin) - unknown_origin) %>%
        filter(marginal_gain < 0.01) %>%
        slice_head(n = 1) %>%
        ungroup() %>%
        pull(durations) %>%
        max()

    points_smooth <- points %>%
        group_by(year, month) %>%
        arrange(size, .by_group = TRUE) %>%
        mutate(
            delta = lag(cv) - cv,
            delta = rollmean(delta, k = 3, fill = NA, align = "right")
        ) %>%
        ungroup() %>%
        summarise(max_delta = max(delta, na.rm = TRUE), .by = size) %>%
        filter(!is.infinite(max_delta))

    max_trajectories <- points_smooth %>%
        arrange(desc(size), max_delta) %>%
        mutate(threshold = cummax(max_delta) > 0.25) %>%
        slice_tail(n = 1, by = threshold) %>%
        filter(threshold == F) %>%
        pull(size) %>%
        {
            plyr::round_any(. / 30, 50, ceiling) * 30
        }

    list(
        max_duration = max_duration,
        points_smooth = points_smooth,
        max_trajectories = max_trajectories
    )
}
