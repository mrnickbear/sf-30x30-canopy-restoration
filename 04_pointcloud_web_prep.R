# 04_pointcloud_web_prep.R
# Step 4: Export per-tree web-ready PLY files for tall trees.
#
# Reads the normalized + segmented LAS from OUTPUT_LAS_PATH and the Phase 3
# crown polygons from CROWNS_GEOJSON_PATH, then clips one buffered point cloud
# per tree taller than WEB_POINT_CLOUD_MIN_HEIGHT_M. Each output contains all
# points within WEB_POINT_CLOUD_BUFFER_M of the tree top and is written to
# WEB_POINT_CLOUD_DIR as a binary PLY file (float32 x/y/z + uint16 intensity).
# PLY avoids LAS 1.3 vs 1.4 version compatibility issues and requires no WASM
# or CDN decompressor in the browser.

source("config.R")

library(lidR)
library(sf)
library(jsonlite)

# ── Write a binary PLY file from a LAS object ────────────────────────────────
# Writes x/y/z as float32 and intensity as uint16 in binary little-endian PLY.
# PLY avoids LAS 1.3 vs 1.4 compatibility issues and parses natively in the
# browser without WASM or CDN dependencies.
write_ply <- function(las, path) {
  dt <- las@data
  n  <- nrow(dt)

  header <- paste0(
    "ply\n",
    "format binary_little_endian 1.0\n",
    "element vertex ", n, "\n",
    "property float x\n",
    "property float y\n",
    "property float z\n",
    "property uint16 intensity\n",
    "end_header\n"
  )

  # Build binary payload: each vertex is float32 x/y/z (3×4 bytes) + uint16
  # intensity (2 bytes) = 14 bytes. Interleave with matrix-transpose trick.
  xm  <- matrix(writeBin(as.numeric(dt$X),         raw(), size = 4L), nrow = n, byrow = TRUE)
  ym  <- matrix(writeBin(as.numeric(dt$Y),         raw(), size = 4L), nrow = n, byrow = TRUE)
  zm  <- matrix(writeBin(as.numeric(dt$Z),         raw(), size = 4L), nrow = n, byrow = TRUE)
  im  <- matrix(writeBin(as.integer(dt$Intensity), raw(), size = 2L), nrow = n, byrow = TRUE)

  # cbind → n×14 matrix; c(t(...)) reads row-by-row → interleaved vertex bytes
  payload <- c(t(cbind(xm, ym, zm, im)))

  con <- file(path, "wb")
  on.exit(close(con))
  writeChar(header, con, eos = NULL)
  writeBin(payload, con)
}

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
written    <- 0L
written_bg <- 0L
# Maps crown treeID (character) -> LAS segment treeID (integer or NA_integer_)
# Written to crown_las_map.json so app.js knows which trees have PLY files.
# Note: use NA_integer_ (not NULL) for missing values — assigning NULL to a named
# R list element removes that key entirely, which would hide the tree from app.js.
crown_las_map <- list()

for (i in seq_len(nrow(clip_windows))) {
  tree_id <- clip_windows$treeID[i]
  output_path <- file.path(
    WEB_POINT_CLOUD_DIR,
    sprintf(paste0("tree_%0", max_tree_id_digits, "d.ply"), tree_id)
  )
  bg_path <- file.path(
    WEB_POINT_CLOUD_DIR,
    sprintf(paste0("tree_%0", max_tree_id_digits, "d_bg.ply"), tree_id)
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
  las_tid <- NULL
  if ("treeID" %in% names(clipped_las@data)) {
    xtop <- clip_windows$XTOP[i]
    ytop <- clip_windows$YTOP[i]
    # Squared distances avoid sqrt; which.min needs only relative ordering.
    dists_sq <- (clipped_las@data$X - xtop)^2 + (clipped_las@data$Y - ytop)^2
    nearest_tid <- clipped_las@data$treeID[which.min(dists_sq)]
    if (!is.na(nearest_tid)) {
      las_tid <- as.integer(nearest_tid)
    }
  }
  # Always record the crown treeID in the map; NA_integer_ (serialised as JSON
  # null) means no segment treeID mapping is available but the file still exists.
  crown_las_map[[as.character(tree_id)]] <- if (is.null(las_tid)) NA_integer_ else las_tid

  # Split the buffered clip into a target file (selected tree's segment only)
  # and a background file (surrounding context) when the LAS segment treeID is
  # known.  Both files are loaded by app.js: target is coloured viridis by
  # elevation; background is rendered as dim grey for spatial context.
  if (!is.null(las_tid) && "treeID" %in% names(clipped_las@data)) {
    target_las <- filter_poi(clipped_las, treeID == las_tid)
    bg_las     <- filter_poi(clipped_las, is.na(treeID) | treeID != las_tid)
  } else {
    target_las <- clipped_las
    bg_las     <- NULL
  }

  if (!is.null(target_las) && nrow(target_las@data) > 0) {
    write_ply(target_las, output_path)
    written <- written + 1L
    message("Wrote ", output_path)
  }
  if (!is.null(bg_las) && nrow(bg_las@data) > 0) {
    write_ply(bg_las, bg_path)
    written_bg <- written_bg + 1L
    message("Wrote ", bg_path)
  }
}

# Write the crown → LAS treeID mapping alongside the per-tree PLY files.
# app.js loads this at startup to resolve which LAS treeID to highlight.
map_path <- file.path(WEB_POINT_CLOUD_DIR, "crown_las_map.json")
writeLines(jsonlite::toJSON(crown_las_map, auto_unbox = TRUE), map_path)
message("Wrote crown_las_map.json to: ", map_path)

message(
  "Web point cloud prep complete. Wrote ", written, " target PLY file(s) and ",
  written_bg, " background PLY file(s) to: ", WEB_POINT_CLOUD_DIR
)

# #tests
# library(mapview)
# mapview(clip_windows)
# 
# test <- readLAS("data/raw_point_clouds/LHH_aa_z3segssnags.las")
# plot(test)


