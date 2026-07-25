# 02_segment.R
# Step 2: Normalize heights, detect tree tops, segment trees, classify snags,
#         and save the result to OUTPUT_LAS_PATH.
#
# This is the most time-consuming step (~2 minutes for the small DLT_040 circle,
# much longer for the full analysis area). Once complete, the saved LAS file can
# be loaded directly in later steps without re-running segmentation.
#
# Inputs (from the R environment or loaded fresh):
#   las  – raw LAS object (from 01_load_data.R)
#          If `las` is not in memory, source 01_load_data.R first.
#
# Outputs (written to file and returned to the R environment):
#   seg_snags – LAS with treeID and snagCls attributes
#               saved to OUTPUT_LAS_PATH
# plot(las)

source("config.R")

library(lidR)
library(sf)
library(stars)
library(scales)
library(FNN)

# ---- Require las in memory ----
if (!exists("las")) {
  stop("'las' is not in memory. Run 01_load_data.R first, ",
       "or set RUN_LOAD_DATA = TRUE in run_pipeline.R.")
}

# ---- Height normalization ----
message("Normalizing heights...")
if (!file.exists(NORMALIZATION_DEM_PATH)) {
  stop("Normalization DEM not found at: ", NORMALIZATION_DEM_PATH)
}
dem <- stars::read_stars(NORMALIZATION_DEM_PATH)
nlas <- normalize_height(las, dem)
nlas <- filter_poi(nlas, Z > MIN_HEIGHT_M)

# # ---- Canopy height model (normalized) ----
# message("Generating canopy height model...")
# chm <- rasterize_canopy(las = nlas, res = CHM_RES, algorithm = p2r(0.15))
# plot(chm, col = height.colors(50), main = "Canopy Height Model (normalized)")

# # ---- Tree top detection ----
# message("Detecting tree tops (lmf, ws = ", TREE_DETECTION_WS, ")...")
# ttops <- locate_trees(nlas, lmf(ws = TREE_DETECTION_WS)) %>% st_set_crs(cs13_m)
# plot(chm, col = height.colors(50), main = "Detected tree tops")
# plot(sf::st_geometry(ttops), add = TRUE, pch = 3)

# # ---- Tree segmentation (slow) ----
# message("Segmenting trees (li2012)... This may take several minutes.")
# seg <- segment_trees(las = nlas, algorithm = li2012())

# 1. Thin the point cloud to a uniform 20-30 points per sq meter for structural tracking
# homogenization ensures a consistent density across both open and dense canopies
seg_thinned <- decimate_points(nlas, homogenize(density = 25, res = 1))

# 2. Segment the thinned cloud (Li algorithm will perform beautifully here)
seg_thinned <- segment_trees(las = seg_thinned, algorithm = li2012(dt1 = 1.2, dt2 = 1.6, R = 5.0, hmin=MIN_HEIGHT_M)) #R=7.0 with dt2=3 for City Hall London Planes, but 

# --- NEW: MAP BACK TO ORIGINAL HIGH-RES DATA ---

# 3. Extract 3D coordinates from both datasets for spatial matching
coords_thinned <- data.frame(X = seg_thinned$X, Y = seg_thinned$Y, Z = seg_thinned$Z)
coords_orig    <- data.frame(X = nlas$X, Y = nlas$Y, Z = nlas$Z)

# 4. Find the closest thinned point for every original high-res point
knn_result <- get.knnx(data = coords_thinned, query = coords_orig, k = 1)

# 5. Extract the treeIDs using the neighbor indices and inject into original cloud
matched_tree_ids <- seg_thinned$treeID[knn_result$nn.index]
seg <- add_attribute(nlas, matched_tree_ids, "treeID")


# seg <- segment_trees(las = nlas, algorithm = li2012(dt1 = 1.2, dt2 = 1.5, R = 10, speed_up = 15))

# plot(seg, color = "treeID") #This is the ID we need to use consistently!!

# # 2. Calculate metrics (this automatically groups by the generated treeID)
# metrics <- crown_metrics(las = seg, func = .stdtreemetrics) %>% st_set_crs(cs13_m)
# 
# # 3. Delineate crowns
# crown_outlines <- delineate_crowns(seg, attribute = "treeID")


# x <- plot(seg, color = "treeID")
# 
# las_new <- filter_poi(seg, X > 50000)
# plot(las_new, color = "treeID")


# # ---- Rescale intensity for snag classification ----
# # Wing (2015) expects 8-bit intensity; the 2023 LiDAR data is 16-bit.
# seg@data[, Intensity := as.integer(Intensity / (2^16 - 1) * MAX_8BIT_INTENSITY)]

# # ---- Snag classification (slow) ----
# message("Classifying snags (wing2015)... This may take several minutes.")
# seg_snags <- segment_snags(
#   seg,
#   wing2015(neigh_radii = c(1.5, 1, 2), BBPRthrsh_mat = BBPR_THRESHOLDS)
# )

# plot(seg_snags, color = "treeID") #This is the ID we need to use consistently!!

# Use add_lasattribute directly to bind the vector and update the LAS header 
seg <- add_lasattribute(
  las  = seg, 
  x    = matched_tree_ids, 
  name = "treeID", 
  desc = "Unique tree ID from segmentation"
)

# #TURN OFF - ID DOESN'T MATCH
# # ---- Crown metrics ----
# message("Computing crown metrics...")
# metrics <- crown_metrics(las = seg, func = .stdtreemetrics)
# st_crs(metrics) <- cs13_m

# ---- Delineate crown polygons ----
message("Delineating crown polygons...")
crown_outlines <- st_as_sf(delineate_crowns(seg, attribute = "treeID"))
st_crs(crown_outlines) <- cs13_m


# Transform sf objects to WGS84 (EPSG:4326) for web mapping
# treetops_web <- st_transform(tree_points %>% st_set_crs(cs13_m), 4326)
crowns_web <- st_transform(crown_outlines %>% st_set_crs(cs13_m), 4326)

# 2. Export to GeoJSON
# delete_dsn = TRUE ensures it overwrites cleanly if you re-run the script

# #generated in script 04
# st_write(treetops_web, "data/vector/treetops.geojson", driver = "GeoJSON", delete_dsn = TRUE)

st_write(crowns_web, "data/vector/crowns.geojson", driver = "GeoJSON", delete_dsn = TRUE)

# ---- Save results ----
message("Saving segmented LAS to: ", OUTPUT_LAS_PATH)
save_ok <- writeLAS(seg, OUTPUT_LAS_PATH, index = FALSE)
if (save_ok != OUTPUT_LAS_PATH) {
  stop("Failed to write segmented LAS to: ", OUTPUT_LAS_PATH)
}

#library(mapview)
#mapview(crowns_web)

# # # Verify treeID persisted in the saved LAS for downstream crown_metrics().
# # seg_check <- readLAS(OUTPUT_LAS_PATH, select = "*")
# # if (is.null(seg_check) || !"treeID" %in% names(seg_check@data)) {
# #   stop("Saved LAS is missing 'treeID'. Segmentation was not persisted to: ",
# #        OUTPUT_LAS_PATH)
# # }
# # message("Segmentation complete. Output saved to: ", OUTPUT_LAS_PATH)
# 
# plot(seg, color = "treeID")
# 
# #plot seg with treeID color, but highlight a specific treeID (e.g., 37) in yellow and make all other trees faint gray.
# 
# # 1. Define your target tree ID
# target_id <- 37
# 
# # 2. Build a color vector directly for every point in the point cloud
# # If treeID matches target_id, make it yellow; otherwise, make it faint gray
# point_colors <- ifelse(seg@data$treeID == target_id, "yellow", rgb(0.5, 0.5, 0.5, 0.1))
# 
# # 3. Plot using the 'col' argument instead of 'color' or 'palette'
# # This bypasses lidR's attribute name checks completely
# plot(seg, col = point_colors, main = paste("Highlighting Tree", target_id))