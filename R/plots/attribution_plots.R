pacman::p_load(tidyverse, networkD3, here, htmlwidgets, webshot2, chromote)

attribution_plot <- function(attribution) {
  
  eco <- attribution$main_ecoregions
  nodes <- data.frame(
    name = unique(c(eco$ecoregion, eco$dest_hydrological_zone))
  )
  
  df_sankey <- eco %>%
    mutate(
      IDsource = match(ecoregion, nodes$name) - 1,
      IDtarget = match(dest_hydrological_zone, nodes$name) - 1
    )
  
  p <- sankeyNetwork(
    Links = df_sankey, 
    Nodes = nodes,
    Source = "IDsource", 
    Target = "IDtarget",
    Value = "contribution_pct", 
    NodeID = "name",
    sinksRight = FALSE,
    margin = list(top = 20, right = 240, bottom = 20, left = 20),
    fontSize = 12, 
    nodeWidth = 25, 
    nodePadding = 10
  )
  
  p <- onRender(p, '
      function(el, x) {
        d3.select(el).selectAll(".node").each(function(d) {
          if (d.x < 10) { // Si está en la columna de la izquierda
            d3.select(this).select("text")
              .attr("x", -10)              // 10 pixeles a la izquierda de la caja
              .attr("text-anchor", "end"); // Crece hacia la izquierda
          }
        });
      }
    ')
  
  country_colors <- c(
    "Brazil"    = "orange", # Verde intenso
    "Colombia"  = "brown", # Naranja brillante
    "Ecuador"   = "#33A02C", # Azul fuerte
    "Peru"      = "#7F7F7F", # Rojo puro
    "Venezuela" = "#6A3D9A"  # Morado oscuro
  )
  
  sankey_plot_path <- here("plots", "basin_sources.png")
  Sys.setenv(CHROMOTE_EXTRA_ARGS = "--no-sandbox --disable-gpu --disable-dev-shm-usage")
  
  set_default_chromote_object(
    Chromote$new(
      browser = Chrome$new(
        args = c(
          "--headless",
          "--no-sandbox",
          "--disable-gpu",
          "--disable-dev-shm-usage"
        )
      )
    )
  )
  
  saveWidget(p, file = here("temp", "temp_sankey.html"), selfcontained = TRUE)
  
  webshot(
    url = here("temp", "temp_sankey.html"),
    file = sankey_plot_path,
    vwidth = 1400,    
    vheight = 900,    
    zoom = 2,         
    delay = 0.5       
  )
  
  file.remove(here("temp", "temp_sankey.html"))
  return(sankey_plot_path)
}

