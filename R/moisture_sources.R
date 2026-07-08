pacman::p_load(DBI, duckdb, dbplyr, dplyr, arrow)

identify_sources <- function(hysplit_files){
  path <- here("output", "results.db")
  con <- dbConnect(duckdb::duckdb(), dbdir = path)
  on.exit(dbDisconnect(con, shutdown = TRUE))

  dbExecute(con, "INSTALL spatial;")
  dbExecute(con, "LOAD spatial;")

  open_dataset(hysplit_files, format = "parquet") %>%
    {duckdb_register_arrow(con, "dataset", .)}

  tbl(con, "dataset") %>%
    group_by(id) %>%
    mutate(pp_at_age_0 = ifelse(age == 0 & rain != 0, 1, 0) %>% max(na.rm = T)) %>%
    filter(pp_at_age_0 == 1) %>%
    window_order(age) %>%
    mutate(
      delta = sphu - lag(sphu, default = 0),
      alpha = ifelse(delta < 0 & rh >= 80 & lag(sphu) > 0, sphu / lag(sphu), 1),
      log_alpha = ifelse(alpha <= 0, 0.0001, alpha) %>% log()
    ) %>%
    window_order(desc(age)) %>%
    mutate(
      factor = cumsum(log_alpha) %>% exp(),
      contribution = ifelse(delta > 0 & height <= bhl, delta * factor, 0),
      has_contr = ifelse(contribution > 0, 1, 0) %>% max()
      ) %>%
    ungroup() %>%
    filter(has_contr == 1) %>%
    mutate(geometry = sql("ST_Point(long, lat)")) %>%
    select(-c(pp_at_age_0, log_alpha, factor, has_contr)) %>%
    compute(name = "sources", temporary = F, overwrite = T)

    return(path)
}