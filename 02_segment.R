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
library(scales)

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
dem <- terra::rast(NORMALIZATION_DEM_PATH)
nlas <- normalize_height(las, dem)
nlas <- filter_poi(nlas, Z > MIN_HEIGHT_M)

# ---- Canopy height model (normalized) ----
message("Generating canopy height model...")
chm <- rasterize_canopy(las = nlas, res = CHM_RES, algorithm = p2r(0.15))
plot(chm, col = height.colors(50), main = "Canopy Height Model (normalized)")

# ---- Tree top detection ----
message("Detecting tree tops (lmf, ws = ", TREE_DETECTION_WS, ")...")
ttops <- locate_trees(nlas, lmf(ws = TREE_DETECTION_WS))
plot(chm, col = height.colors(50), main = "Detected tree tops")
plot(sf::st_geometry(ttops), add = TRUE, pch = 3)

# ---- Tree segmentation (slow) ----
message("Segmenting trees (li2012)... This may take several minutes.")
seg <- segment_trees(las = nlas, algorithm = li2012())

# ---- Rescale intensity for snag classification ----
# Wing (2015) expects 8-bit intensity; the 2023 LiDAR data is 16-bit.
seg@data[, Intensity := as.integer(Intensity / (2^16 - 1) * MAX_8BIT_INTENSITY)]

# ---- Snag classification (slow) ----
message("Classifying snags (wing2015)... This may take several minutes.")
seg_snags <- segment_snags(
  seg,
  wing2015(neigh_radii = c(1.5, 1, 2), BBPRthrsh_mat = BBPR_THRESHOLDS)
)

# ---- Save results ----
message("Saving segmented LAS to: ", OUTPUT_LAS_PATH)
writeLAS(seg_snags, OUTPUT_LAS_PATH, index = FALSE)
message("Segmentation complete. Output saved to: ", OUTPUT_LAS_PATH)
