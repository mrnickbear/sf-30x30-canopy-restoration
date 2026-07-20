# 01_load_data.R
# Step 1: Load the LiDAR catalog and clip it to the analysis area.
#
# Outputs (written to the R environment):
#   ctg  – LASCatalog covering all source tiles
#   aa   – sf polygon for the analysis area (projected to cs13_m)
#   las  – LAS object clipped to the analysis area

source("config.R")

library(lidR)
library(sf)

# ---- Load LiDAR catalog ----
message("Loading LiDAR catalog from: ", LIDAR_CATALOG_PATH)
ctg <- readLAScatalog(LIDAR_CATALOG_PATH)

# ---- Define analysis area ----
if (USE_CUSTOM_CIRCLE) {
  message("Using DLT_040 test circle  (center = [",
          CIRCLE_CENTER_X, ", ", CIRCLE_CENTER_Y,
          "],  r = ", CIRCLE_RADIUS, " m)")
  center_point <- st_sfc(
    st_point(c(x = CIRCLE_CENTER_X, y = CIRCLE_CENTER_Y)),
    crs = cs13_m
  )
  aa <- st_buffer(center_point, dist = CIRCLE_RADIUS)
} else {
  message("Using analysis area from: ", AOI_KML_PATH)
  aa <- st_cast(st_read(AOI_KML_PATH), "POLYGON")
  aa <- st_zm(aa, drop = TRUE, what = "ZM")
  aa <- aa[1, ]
  aa <- st_transform(aa, cs13_m)
}

# ---- Clip LiDAR to analysis area ----
message("Clipping LiDAR to analysis area...")
las <- clip_roi(ctg, aa)
message("Done. LAS object has ", nrow(las@data), " points.")

library(mapview)
mapview(aa)