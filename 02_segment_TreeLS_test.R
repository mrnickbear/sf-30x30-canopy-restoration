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

source("config.R")

library(lidR)
library(sf)
library(stars)
library(scales)
library(FNN)
# library(crownsegmentr)  Recommends 5-20 ppm
library(TreeLS) #segmentation from bottom up using stems/branches
# library(remotes)
# library(usethis)

# library(rgl)
# # 1. Manage the persistent device
# if (rgl.cur() == 0) {
#   # If no window is open, open a new one and store the ID
#   .GlobalEnv$my_rgl_dev <- open3d()
# } else {
#   # If a window is already open, make it active
#   set3d(.GlobalEnv$my_rgl_dev)
#   # Optional: clear it to prevent old layers from piling up
#   clear3d() 
# }



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


# #lidr approach
# # 1. Thin the point cloud to a uniform 20-30 points per sq meter for structural tracking
# # homogenization ensures a consistent density across both open and dense canopies
# seg_thinned <- decimate_points(nlas, homogenize(density = 50, res = 1))
# 
# # # 2. Segment the thinned cloud (Li algorithm will perform beautifully here)
# seg_thinned <- segment_trees(las = seg_thinned, algorithm = li2012(dt1 = 1.2, dt2 = 1.6, R = 2.0))
# 
# plot(seg_treels, color = "treeID")
# #end lidr


# TreeLS approach: bottom-up segmentation using stems and branches
# extract the tree map from a thinned point cloud

# normalize the point cloud
tls = tlsNormalize(las, keep_ground = F)
x = plot(tls)

# use Hough
#
# thin = tlsSample(tls, smp.voxelize(0.1))
# map = treeMap(thin, map.hough(min_density = 0.001), 0)
# add_treeMap(x, map, color='yellow', size=2) #Blank window - too much data??
# 
# # classify tree regions
# tls = treePoints(tls, map, trp.crop())
# 
# # set3d(.GlobalEnv$my_rgl_dev)
# add_treePoints(x, tls, size=4)
# 
# # set3d(.GlobalEnv$my_rgl_dev)
# add_treeIDs(x, tls, cex = 2, col='yellow')
# 
# # classify stem points
# tls = stemPoints(tls, stm.hough())
#
# add_stemPoints(x, tls, color='red', size=8)
# message("Points after stemPoints: ", nrow(tls@data))
# 
# # make the plot's inventory
# inv = tlsInventory(tls, d_method=shapeFit(shape='circle', algorithm = 'irls'))
# add_tlsInventory(x, inv)
#
# /use Hough

# 1. Use lidR to find the "Trunk Centers"
trunks <- locate_trees(nlas, lmf(ws = 3, hmin = 1)) %>% st_set_crs(cs13_m)
trunks_coords <- cbind(trunks, st_coordinates(trunks))

# 2. Build a PURE data.frame (no sf baggage, no spatial metadata)
manual_map <- data.frame(
  TreeID = as.integer(trunks_coords$treeID), # Must be capitalized TreeID and integer
  X      = as.numeric(trunks_coords$X),
  Y      = as.numeric(trunks_coords$Y),
  Radius = 0.1,                              # Dummy column expected by TreeLS
  Error  = 0.0                               # Dummy column expected by TreeLS
)

# Rename 'treeID' to 'TreeID' (TreeLS explicitly looks for a capitalized 'TreeID' column)
names(manual_map)[names(manual_map) == "treeID"] <- "TreeID"

# 3. Explicitly set the class required by TreeLS
class(manual_map) <- c("tree_map", class(manual_map))

# 3. Feed these known coordinates into treeLS
# Because it is still an sf object, TreeLS can natively read the geometry
tls_segmented <- treePoints(tls, manual_map, trp.crop(r = 5))

# 4. Now that we have the points, we can proceed with treeLS inventory
# Since we have the point-to-tree assignment, we don't need the Hough-circle step
inv <- tlsInventory(tls_segmented, d_method=shapeFit(shape='circle', algorithm = 'irls'))

# 5. Visualize
x <- plot(tls_segmented, color = "treeID")
add_tlsInventory(x, inv)




# extract stem measures
seg = stemSegmentation(tls, sgt.ransac.circle(n = 20))
add_stemSegments(x, seg, color='white', fast=T)
message("Segments found: ", nrow(seg))

if(nrow(seg) == 0) {
  stop("Segmentation failed: No stems were detected. Check your point density or normalization.")
}

# plot everything once
tlsPlot(tls, map, inv, seg, fast=T)
# end TreeLS



# --- NEW: MAP BACK TO ORIGINAL HIGH-RES DATA ---

# 3. Extract 3D coordinates from both datasets for spatial matching
coords_thinned <- data.frame(X = seg_thinned$X, Y = seg_thinned$Y, Z = seg_thinned$Z)
coords_orig    <- data.frame(X = nlas$X, Y = nlas$Y, Z = nlas$Z)

# 4. Find the closest thinned point for every original high-res point
knn_result <- get.knnx(data = coords_thinned, query = coords_orig, k = 1)

# 5. Extract the treeIDs using the neighbor indices and inject into original cloud
matched_tree_ids <- seg_thinned$treeID[knn_result$nn.index]
seg <- add_attribute(nlas, matched_tree_ids, "treeID") %>% st_set_crs(cs13_m)


# seg <- segment_trees(las = nlas, algorithm = li2012(dt1 = 1.2, dt2 = 1.5, R = 10, speed_up = 15))

# plot(seg, color = "treeID") #This is the ID we need to use consistently!!

# # 2. Calculate metrics (this automatically groups by the generated treeID)
# metrics <- crown_metrics(las = seg, func = .stdtreemetrics) %>% st_set_crs(cs13_m)
# 
# # 3. Delineate crowns
# crown_outlines <- delineate_crowns(seg, attribute = "treeID")


# x <- plot(seg, color = "treeID")


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


crowns_above_threshold <- subset(
  crown_outlines,
  ZTOP > WEB_POINT_CLOUD_MIN_HEIGHT_M
)

if (nrow(crowns_above_threshold) == 0) {
  stop("No crowns exceed ", WEB_POINT_CLOUD_MIN_HEIGHT_M,
       " m in ", CROWNS_GEOJSON_PATH)
}

tree_points <- st_sf(
  crowns_above_threshold,
  geometry = st_sfc(
    Map(
      function(x, y) st_point(c(x, y)),
      crowns_above_threshold$XTOP,
      crowns_above_threshold$YTOP
    ),
    crs = st_crs(seg)
  )
)

clip_windows <- st_buffer(tree_points, dist = WEB_POINT_CLOUD_BUFFER_M)
if (nrow(clip_windows) == 0) {
  stop("No buffered clip windows were created from ", CROWNS_GEOJSON_PATH)
}


dir.create(WEB_POINT_CLOUD_DIR, recursive = TRUE, showWarnings = FALSE)
existing_outputs <- Sys.glob(file.path(WEB_POINT_CLOUD_DIR, "*.las"))
if (length(existing_outputs) > 0) {
  message("Removing ", length(existing_outputs),
          " existing LAS file(s) from: ", WEB_POINT_CLOUD_DIR)
  file.remove(existing_outputs)
}



# max_tree_id_digits <- max(nchar(as.character(clip_windows$treeID)))
# tree_id_pad_width_path <- file.path(WEB_POINT_CLOUD_DIR, "tree_id_pad_width.txt")
# writeLines(as.character(max_tree_id_digits), tree_id_pad_width_path)
# message("Wrote tree_id_pad_width.txt to: ", tree_id_pad_width_path)
written <- 0L
# Maps crown treeID (character) -> LAS segment treeID (integer)
# Written to crown_las_map.json so app.js can colour the correct tree.
crown_las_map <- list()


for (i in seq_len(nrow(clip_windows))) {
  tree_id <- clip_windows$treeID[i]
  output_path <- file.path(
    WEB_POINT_CLOUD_DIR,
    sprintf(paste0("tree_%0", max_tree_id_digits, "d.las"), tree_id)
  )
  
  clipped_las <- clip_roi(seg, clip_windows[i, ])
  if (is.null(clipped_las) || nrow(clipped_las@data) == 0) {
    message("Skipping tree ", tree_id, ": no points found in buffered clip.")
    next
  }
  
  # The treeID attribute in the LAS is assigned by segment_trees() and may not
  # match the crown treeID from crowns.geojson.  Find the LAS treeID of the
  # point nearest to this crown's treetop (XTOP, YTOP) so the browser can
  # highlight the correct segment.
  if ("treeID" %in% names(clipped_las@data)) {
    xtop <- clip_windows$XTOP[i]
    ytop <- clip_windows$YTOP[i]
    # Squared distances avoid sqrt; which.min needs only relative ordering.
    dists_sq <- (clipped_las@data$X - xtop)^2 + (clipped_las@data$Y - ytop)^2
    nearest_tid <- clipped_las@data$treeID[which.min(dists_sq)]
    if (!is.na(nearest_tid)) {
      crown_las_map[[as.character(tree_id)]] <- as.integer(nearest_tid)
    }
  }

  plot(clipped_las, color = "treeID")
  
  
  
  # Transform sf objects to WGS84 (EPSG:4326) for web mapping
  # ERROR: the transformed points look like a pole
  clipped_wgs84 <- st_transform(clipped_las, crs = 4326, xoffset = 0, yoffset = 0, zoffset = 0)
  

  
  xy <- clipped_wgs84@data[, c("X", "Y")]
  if (
    any(!is.finite(xy$X) | !is.finite(xy$Y)) ||
    any(abs(xy$Y) > 90, na.rm = TRUE) ||
    any(abs(xy$X) > 180, na.rm = TRUE)
  ) {
    stop(
      "Per-tree LAS export has non-WGS84 coordinates after st_transform(..., 4326). ",
      "Check CRS assignment for seg/clipped_las (expected EPSG:", cs13_m, ") before transforming."
    )
  }
  writeLAS(clipped_wgs84, output_path, index = FALSE)  
  
  written <- written + 1L
  message("Wrote ", output_path)
}

# #IS THIS STILL NEEDED?
# 
# # Write the crown → LAS treeID mapping alongside the per-tree LAS files.
# # app.js loads this at startup to resolve which LAS treeID to highlight.
# map_path <- file.path(WEB_POINT_CLOUD_DIR, "crown_las_map.json")
# writeLines(jsonlite::toJSON(crown_las_map, auto_unbox = TRUE), map_path)
# message("Wrote crown_las_map.json to: ", map_path)

message(
  "Web point cloud prep complete. Wrote ", written, " LAS file(s) to: ",
  WEB_POINT_CLOUD_DIR
)


# Transform sf objects to WGS84 (EPSG:4326) for web mapping
treetops_web <- st_transform(tree_points, 4326)
crowns_web <- st_transform(crown_outlines, 4326)

# 2. Export to GeoJSON
# delete_dsn = TRUE ensures it overwrites cleanly if you re-run the script

# #generated in script 04
st_write(treetops_web, "data/vector/treetops.geojson", driver = "GeoJSON", delete_dsn = TRUE)
st_write(crowns_web, "data/vector/crowns.geojson", driver = "GeoJSON", delete_dsn = TRUE)


# ---- Save results ----
message("Saving segmented LAS to: ", OUTPUT_LAS_PATH)
save_ok <- writeLAS(seg, OUTPUT_LAS_PATH, index = FALSE)
if (save_ok != OUTPUT_LAS_PATH) {
  stop("Failed to write segmented LAS to: ", OUTPUT_LAS_PATH)
}

# # Verify treeID persisted in the saved LAS for downstream crown_metrics().
# seg_check <- readLAS(OUTPUT_LAS_PATH, select = "*")
# if (is.null(seg_check) || !"treeID" %in% names(seg_check@data)) {
#   stop("Saved LAS is missing 'treeID'. Segmentation was not persisted to: ",
#        OUTPUT_LAS_PATH)
# }
# message("Segmentation complete. Output saved to: ", OUTPUT_LAS_PATH)
