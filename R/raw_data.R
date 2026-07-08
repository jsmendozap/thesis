pacman::p_load(tidytable, nanoparquet, here)

process_trajectories <- function(file) {
  dt<- gsub("_", "", substr(basename(file), 6, 18))
  path <- here("data", "processed", paste0("hysplit_", dt, ".parquet"))          

  fread(cmd = paste("awk '/PRESSURE/, EOF'",  shQuote(file)), 
        col.names = c("traj_id", "met_file", "year", "month", "day",
                      "hour", "minute", "forecast_hour", "age", "lat",
                      "long", "height", "pressure", "rain", "bhl", "rh", "sphu")) %>%
    mutate(date = paste(year, month, day, hour, minute) %>%
            as.POSIXct(format="%y %m %d %H %M", tz = "UTC"),
          id = as.numeric(sprintf("%s%03d", dt, traj_id))) %>%
    select(id, date, age, lat, long, height, pressure, sphu, rh, bhl, rain) %>%
    write_parquet(path)

  return(path)
}
