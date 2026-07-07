# 03_visualize.R
# Step 3: Load segmentation results and create an interactive map.
#
# Reads the saved LAS from OUTPUT_LAS_PATH (written by 02_segment.R),
# computes crown metrics and crown polygons, and displays an interactive
# tmap overlaid on the SF Pictometry 2024 aerial imagery.
#
# Inputs (from file):
#   OUTPUT_LAS_PATH – segmented LAS with treeID and snagCls attributes
#
# Outputs (written to the R environment):
#   metrics        – sf data frame of per-tree crown metrics
#   crown_outlines – sf polygon layer of all tree crowns
#   snag_outlines  – sf polygon layer of snag crowns only

source("config.R")

library(lidR)
library(sf)
library(tmap)
library(leaflet)

# ---- Load segmented LAS ----
message("Loading segmented LAS from: ", OUTPUT_LAS_PATH)
seg_snags <- readALSLAS(OUTPUT_LAS_PATH, filter = "-drop_z_below 10")

# ---- Crown metrics ----
message("Computing crown metrics...")
metrics <- crown_metrics(las = seg_snags, func = .stdtreemetrics)
st_crs(metrics) <- cs13_m

# ---- Identify snag points ----
# Snag class codes (Wing 2015):
#   0 = Live tree
#   1 = General snag
#   2 = Small snag
#   3 = Live crown edge snag
#   4 = High canopy cover snag
snags <- filter_poi(seg_snags, snagCls > 0)

# ---- Delineate crown polygons ----
message("Delineating crown polygons...")
crown_outlines <- st_as_sf(delineate_crowns(seg_snags, attribute = "treeID"))
st_crs(crown_outlines) <- cs13_m

snag_outlines <- st_as_sf(delineate_crowns(snags, attribute = "treeID"))
st_crs(snag_outlines) <- cs13_m

# ---- Interactive map ----
message("Building interactive map...")
tmap_mode("view")

tmap_sf_aerial <- tm_shape(crown_outlines) +
  tm_borders(border.col = "grey", fill = NA, lwd = 0.5, alpha = 0) +
  tm_shape(snag_outlines) +
  tm_borders(border.col = "red", lwd = 2, alpha = 0) +
  tm_shape(metrics) +
  tm_dots(
    col   = "Z",
    palette = "viridis",
    title = "Height (m)"
  )

tmap_sf_aerial <- 
  tmap_leaflet(tmap_sf_aerial) |>
  addTiles(
    urlTemplate = PICTOMETRY_URL,
    options = tileOptions(maxZoom = 22, maxNativeZoom = 22)
  )

print(tmap_sf_aerial)