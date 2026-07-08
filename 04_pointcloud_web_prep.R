# 04_pointcloud_web_prep.R
# Step 4: Export per-tree web-ready LAS files for tall trees.
#
# Reads the normalized + segmented LAS from OUTPUT_LAS_PATH and the Phase 3
# crown polygons from CROWNS_GEOJSON_PATH, then clips one buffered point cloud
# per tree taller than WEB_POINT_CLOUD_MIN_HEIGHT_M. Each output contains all
# points within WEB_POINT_CLOUD_BUFFER_M of the tree top and is written to
# WEB_POINT_CLOUD_DIR as an individual uncompressed .las file (no WASM/CDN
# decompressor required in the browser).

source("config.R")

library(lidR)
library(sf)

if (!file.exists(OUTPUT_LAS_PATH)) {
  stop("Segmented LAS not found at: ", OUTPUT_LAS_PATH,
       ". Run 02_segment.R first.")
}

if (!file.exists(CROWNS_GEOJSON_PATH)) {
  stop("Crown polygons not found at: ", CROWNS_GEOJSON_PATH,
       ". Create or copy the Phase 3 crown export to this path first.")
}

message("Loading segmented LAS from: ", OUTPUT_LAS_PATH)
seg_snags <- readLAS(OUTPUT_LAS_PATH)

if (is.null(seg_snags) || nrow(seg_snags@data) == 0) {
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
    crs = st_crs(seg_snags)
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

max_tree_id_digits <- max(nchar(as.character(clip_windows$treeID)))
written <- 0L

for (i in seq_len(nrow(clip_windows))) {
  tree_id <- clip_windows$treeID[i]
  output_path <- file.path(
    WEB_POINT_CLOUD_DIR,
    sprintf(paste0("tree_%0", max_tree_id_digits, "d.las"), tree_id)
  )

  clipped_las <- clip_roi(seg_snags, clip_windows[i, ])
  if (is.null(clipped_las) || nrow(clipped_las@data) == 0) {
    message("Skipping tree ", tree_id, ": no points found in buffered clip.")
    next
  }

  writeLAS(clipped_las, output_path, index = FALSE)
  written <- written + 1L
  message("Wrote ", output_path)
}

message(
  "Web point cloud prep complete. Wrote ", written, " LAS file(s) to: ",
  WEB_POINT_CLOUD_DIR
)
