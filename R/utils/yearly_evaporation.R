pacman::p_load(tidyverse, terra, tidyterra, exactextractr)

get_yearly_evaporation <- function(aoi){
  # units: m/day (negative because the flux is upward)
  evaporation <- rast("data/single_levels.nc") %>% select(starts_with("e"))
  days_month <- time(evaporation) %>% days_in_month() %>% as.numeric
  
  # Change of units to mm/month
  evaporation <- evaporation * -1000 * days_month
  evaporation <- evaporation %>%
    tapp(index = "years", fun = sum, na.rm = TRUE) %>%
    exact_extract(aoi, 'mean') %>%
    mutate(hydrological_zone = aoi$nom_zh) %>%
    pivot_longer(
      cols = starts_with("mean"),
      names_to = "year",
      names_prefix = "mean.Y", 
      values_to = "evap_mm_year"
    ) %>%
    summarise(
      evaporation_mm_year = mean(evap_mm_year, na.rm = TRUE), 
      .by = hydrological_zone
    )
  
  
  
}
