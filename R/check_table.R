check_table <- function(path, name, rows = 50) {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  
  dplyr::tbl(con, name) %>% 
    utils::head(rows) %>% 
    dplyr::collect()
}
