# LHHtrees2023/app.R
# Shiny app for interactive exploration of LHH tree-segmentation results.
#
# Deploy to shinyapps.io by uploading this file together with the
# pre-computed LAS file produced by 02_segment.R (OUTPUT_LAS_PATH).
#
# To run locally:
#   shiny::runApp("LHHtrees2023")
# or open this file in RStudio and click "Run App".

# ---- Shared configuration ----
# When running locally the config lives one directory up; when deployed to
# shinyapps.io it should be bundled in the same directory as this file.
config_path <- if (file.exists("../config.R")) "../config.R" else "config.R"
source(config_path)

# ---- Packages ----
library(lidR)
library(sf)
library(tmap)
library(shiny)

# ---- Load pre-computed segmentation results ----
# Run 02_segment.R first to generate this file.
seg_snags <- readALSLAS(OUTPUT_LAS_PATH, filter = "-drop_z_below 10")

# ---- Compute derived layers ----
metrics <- crown_metrics(las = seg_snags, func = .stdtreemetrics)

# Snag class codes (Wing 2015):
#   0 = Live tree  1 = General snag  2 = Small snag
#   3 = Live crown edge snag  4 = High canopy cover snag
snags <- filter_poi(seg_snags, snagCls > 0)

crown_outlines <- st_as_sf(delineate_crowns(seg_snags, attribute = "treeID"))
st_crs(crown_outlines) <- cs13_m

snag_outlines <- st_as_sf(delineate_crowns(snags, attribute = "treeID"))
st_crs(snag_outlines) <- cs13_m
st_crs(metrics) <- cs13_m

# ---- Base tmap object ----
tmap_mode("view")

tmap_sf_aerial <- tm_shape(crown_outlines) +
  tm_borders(border.col = "grey", fill = NA, lwd = 0.5, alpha = 0) +
  tm_shape(snag_outlines) +
  tm_borders(border.col = "red", lwd = 2, alpha = 0) +
  tm_shape(metrics) +
  tm_dots(
    col     = "Z",
    palette = "viridis",
    title   = "Height (m)"
  )

# ---- Shiny UI ----
ui <- fillPage(
  titlePanel("LHH Tree Canopy Explorer"),
  mainPanel(
    tmapOutput("my_tmap", width = "100%", height = "100%")
  )
)

# ---- Shiny server ----
server <- function(input, output) {
  output$my_tmap <- renderTmap({
    tmap_sf_aerial +
      tm_basemap(
        server          = PICTOMETRY_URL,
        group           = "SF Pictometry 2024",
        max.native.zoom = 22
      ) +
      tm_view(lat = 37.7749, lon = -122.4194, zoom = 14)
  })
}

# ---- Launch ----
shinyApp(ui = ui, server = server)