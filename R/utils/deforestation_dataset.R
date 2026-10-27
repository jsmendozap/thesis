#library(tidyverse)
#library(jsonlite)
#library(rgee)

download_hansen_data <- function(){
  # 1. Initialize Google Earth Engine
  ee_Initialize()
  
  # 2. Define Region of Interest (ROI) using a bounding box
  bbox <- ee$Geometry$Rectangle(coords = c(-80, -35, 20, 30), geodesic = FALSE)
  
  # 3. Load and prepare vector datasets
  # Simplify ecoregion geometries to optimize computational performance
  ecoregions <- ee$FeatureCollection("RESOLVE/ECOREGIONS/2017")$
    filterBounds(bbox)$
    map(function(f) f$simplify(maxError = 500))
  
  countries <- ee$FeatureCollection("USDOS/LSIB_SIMPLE/2017")$
    filterBounds(bbox)
  
  # 4. Create an integer mapping for each unique country name
  country_list <- countries$aggregate_array("country_na")$distinct()
  n_countries  <- country_list$size()
  index        <- ee$List$sequence(0, n_countries$subtract(1))
  
  # Server-side dictionary: country_name -> integer_id
  dict_countries <- ee$Dictionary$fromLists(country_list, index)
  
  # Assign the integer ID to each country feature
  countries_id <- countries$map(function(f) {
    name <- f$get("country_na")
    id   <- ee$Number(dict_countries$get(name))
    f$set("country_id", id)
  })
  
  # 5. Prepare forest loss data and combine bands
  # Hansen dataset: lossyear band contains integers 1-25 representing years 2001-2025
  lossyear <- ee$Image("UMD/hansen/global_forest_change_2025_v1_13")$select("lossyear")
  
  # 6. Rasterize country boundaries to match raster resolutions
  img_countries <- countries_id$
    reduceToImage(properties = list("country_id"), reducer = ee$Reducer$mode())$
    reproject(crs = lossyear$projection())$
    rename("country_id")$
    toInt()
  
  # Combine lossyear (band 0) and country_id (band 1) into a single image
  lossyear_country <- lossyear$addBands(img_countries)
  
  # 7. Compute zonal statistics using a grouped frequency histogram
  # Reduces computation by grouping lossyear frequencies by country_id per ecoregion
  histogram <- lossyear_country$reduceRegions(
    collection = ecoregions,
    reducer    = ee$Reducer$frequencyHistogram()$group(
      groupField = 1, # Band index corresponding to 'country_id'
      groupName  = "country_id"
    ),
    scale      = 30,
    crs        = "EPSG:4326",
    tileScale  = 32
  )$select(
    propertySelectors = c("ECO_NAME", "groups"),
    retainGeometry    = FALSE
  )
  
  # 8. Export result table to Google Drive as CSV
  tarea <- ee_table_to_drive(
    collection  = histogram,
    description = "forest_loss_ecoregions",
    fileFormat  = "CSV",
    folder      = "GEE_Exports"
  )
  
  tarea$start()
  ee_monitoring(tarea)
  
  # -------------------------------------------------------------------------
  # Post-processing in R 
  # -------------------------------------------------------------------------
  
  # Retrieve country lookup dictionary to translate IDs back to names
  country_values <- dict_countries$getInfo()
  id_to_name     <- setNames(names(country_values), unlist(country_values))
  
  # Clean and transform tabular output
  read.csv("forest_loss_ecoregions.csv") %>%
    mutate(
      # Convert GEE key=value syntax into valid JSON format
      groups = str_replace_all(groups, "([a-zA-Z0-9_]+)=", '"\\1":'),
      groups = map(groups, ~fromJSON(., simplifyDataFrame = FALSE))
    ) %>%
    unnest(groups) %>%
    unnest_wider(groups) %>%
    mutate(COUNTRY = id_to_name[as.character(country_id)]) %>%
    unnest_wider(histogram) %>%
    select(-country_id, -any_of("0")) %>%
    rename_with(~ paste0("loss_", as.numeric(.x) + 2000), matches("^[0-9]+$")) %>% 
    mutate(
      source_name = paste(COUNTRY, ECO_NAME, sep = " - "),
      across(.cols = starts_with("loss"), ~ .x * 30^2 * 1e-6),
      across(starts_with("loss_"), ~ replace_na(.x, 0)),
      .keep = "none"
    ) %>%
    relocate(source_name, str_sort(tidyselect::peek_vars(), numeric = TRUE)) %>%
    write_csv("forest_loss_hansen.csv")
  
}

