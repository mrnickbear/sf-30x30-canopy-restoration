# 04_pointcloud_web_prep.R
# Step 4: Export per-tree web-ready PLY files for tall trees.
#
# Reads the normalized + segmented LAS from OUTPUT_LAS_PATH and the Phase 3
# crown polygons from CROWNS_GEOJSON_PATH, then clips one buffered point cloud
# per tree taller than WEB_POINT_CLOUD_MIN_HEIGHT_M.  For each tree, two PLY
# files are written to WEB_POINT_CLOUD_DIR:
#   tree_XXXX_target.ply     – points belonging to the target tree (treeID match)
#   tree_XXXX_background.ply – all other points within the buffer
# The browser renders the target viridis-by-elevation and the background grey.

source("config.R")

library(lidR)
library(sf)
library(jsonlite)
# library(data.table) #fwrite
library(Rvcg) #ply write



if (!file.exists(OUTPUT_LAS_PATH)) {
  stop("Segmented LAS not found at: ", OUTPUT_LAS_PATH,
       ". Run 02_segment.R first.")
}

# if (!file.exists(CROWNS_GEOJSON_PATH)) {
#   stop("Crown polygons not found at: ", CROWNS_GEOJSON_PATH,
#        ". Create or copy the Phase 3 crown export to this path first.")
# }

message("Loading segmented LAS from: ", OUTPUT_LAS_PATH)
seg <- readLAS(OUTPUT_LAS_PATH)

# plot(seg, color = "treeID") #This is the ID we need to use consistently!!


if (is.null(seg) || nrow(seg@data) == 0) {
  stop("Segmented LAS is empty: ", OUTPUT_LAS_PATH)
}

message("Loading crowns from: ", CROWNS_GEOJSON_PATH)
crowns <- st_read(CROWNS_GEOJSON_PATH, quiet = TRUE)

required_columns <- c("treeID", "XTOP", "YTOP", "ZTOP")
missing_columns <- setdiff(required_columns, names(crowns))
if (length(missing_columns) > 0) {
  stop("Crowns file is missing required column(s): ",
       paste(missing_columns, collapse = ", "))
}

tree_ids <- suppressWarnings(as.integer(crowns$treeID))
if (anyNA(tree_ids)) {
  stop("Crowns treeID values must be integer-like.")
}
crowns$treeID <- tree_ids

crowns_above_threshold <- subset(
  crowns,
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
existing_outputs <- Sys.glob(file.path(WEB_POINT_CLOUD_DIR, "*.ply"))
if (length(existing_outputs) > 0) {
  message("Removing ", length(existing_outputs),
          " existing PLY file(s) from: ", WEB_POINT_CLOUD_DIR)
  file.remove(existing_outputs)
}

# max_tree_id_digits <- max(nchar(as.character(clip_windows$treeID)))
written <- 0L
# Maps crown treeID (character) -> LAS segment treeID (integer)
# Written to crown_las_map.json so app.js can colour the correct tree.
crown_las_map <- list()

for (i in seq_len(nrow(clip_windows))) {
  tree_id <- clip_windows$treeID[i]
  target_path <- file.path(
    WEB_POINT_CLOUD_DIR,
    sprintf(paste0("tree_%0", max_tree_id_digits, "d_target.ply"), tree_id)
  )
  bg_path <- file.path(
    WEB_POINT_CLOUD_DIR,
    sprintf(paste0("tree_%0", max_tree_id_digits, "d_background.ply"), tree_id)
  )

  clipped_las <- clip_roi(seg, clip_windows[i, ])
  if (is.null(clipped_las) || nrow(clipped_las@data) == 0) {
    message("Skipping tree ", tree_id, ": no points found in buffered clip.")
    next
  }

  # Default: all clipped points go to target, no background split.
  # Overridden below when treeID data is available and a nearest_tid is found.
  target_pts <- as.matrix(clipped_las@data[, .(X, Y, Z)])
  bg_pts     <- NULL

  # Identify the LAS treeID of the point nearest the crown treetop so we can
  # split target vs background and record the mapping for crown_las_map.json.
  if ("treeID" %in% names(clipped_las@data)) {
    xtop <- clip_windows$XTOP[i]
    ytop <- clip_windows$YTOP[i]
    # Squared distances avoid sqrt; which.min needs only relative ordering.
    dists_sq <- (clipped_las@data$X - xtop)^2 + (clipped_las@data$Y - ytop)^2
    nearest_tid <- clipped_las@data$treeID[which.min(dists_sq)]
    if (!is.na(nearest_tid)) {
      crown_las_map[[as.character(tree_id)]] <- as.integer(nearest_tid)
      target_mask <- clipped_las@data$treeID == nearest_tid
      target_pts  <- as.matrix(clipped_las@data[target_mask,  .(X, Y, Z)])
      bg_pts      <- as.matrix(clipped_las@data[!target_mask, .(X, Y, Z)])
    }
  }

  vcgPlyWrite(target_pts, target_path)
  message("Wrote ", target_path)
  if (!is.null(bg_pts) && nrow(bg_pts) > 0) {
    vcgPlyWrite(bg_pts, bg_path)
    message("Wrote ", bg_path)
  }

  written <- written + 1L
}

# Write the crown → LAS treeID mapping alongside the per-tree LAS files.
# app.js loads this at startup to resolve which LAS treeID to highlight.
map_path <- file.path(WEB_POINT_CLOUD_DIR, "crown_las_map.json")
writeLines(jsonlite::toJSON(crown_las_map, auto_unbox = TRUE), map_path)
message("Wrote crown_las_map.json to: ", map_path)

message(
  "Web point cloud prep complete. Wrote ", written, " file(s) to: ",
  WEB_POINT_CLOUD_DIR
)

# #tests
# library(mapview)
# mapview(clip_windows)
# 
# test <- readLAS("data/web_point_clouds/tree_37.las")
# plot(test)


