# config.R
# Shared configuration for the LHH canopy analysis pipeline.
# source("config.R") at the top of any pipeline script to load these values.

# ---- Coordinate Reference Systems ----
cs13_m <- 7131  # CA State Plane Zone 3, meters
cs13_f <- 7132  # CA State Plane Zone 3, feet

# ---- File Paths ----
# Directory containing the raw LAZ/LAS tiles
LIDAR_CATALOG_PATH <- "tilecls/"

# Path for the segmented output LAS (written by 02_segment.R, read by 03_visualize.R)
OUTPUT_LAS_PATH <- "LHH_aa_z3segssnags.las"

# ---- Analysis Area ----
# Set USE_CUSTOM_CIRCLE = TRUE to use the small DLT_040 test circle (fast, ~5000 sq m).
# Set to FALSE to use the full analysis area from the KML file (~134,000 sq m).
USE_CUSTOM_CIRCLE <- FALSE
AOI_KML_PATH      <- "updatedAA.kml"

# DLT_040 test circle parameters (used when USE_CUSTOM_CIRCLE = TRUE)
CIRCLE_CENTER_X <- 47200
CIRCLE_CENTER_Y <- 23900
CIRCLE_RADIUS   <- 40   # meters

# ---- Processing Parameters ----
CHM_RES          <- 0.5   # Canopy height model resolution (meters)
MIN_HEIGHT_M     <- 3     # Drop points below this height after normalization (meters)
TREE_DETECTION_WS <- 10  # Window size for local maximum filter (lmf)

# Snag classification thresholds (Wing et al. 2015 BBPRthrsh_mat)
# Rows = lower / middle / upper height strata
# Cols = BPR iter1, BrPR iter1, BPR iter2, BrPR iter2
# Lowered slightly from the paper defaults because the 2023 LiDAR data has no 0-intensity points.
BBPR_THRESHOLDS <- matrix(
  c(0.70, 0.70, 0.60, 0.75,
    0.75, 0.50, 0.70, 0.70,
    0.50, 0.80, 0.80, 0.45),
  nrow = 3, ncol = 4
)

# ---- Intensity rescaling ----
# Wing (2015) snag classification expects 8-bit intensity.
# The 2023 LiDAR data is 16-bit, so we rescale: round(I / (2^16 - 1) * MAX_8BIT_INTENSITY).
MAX_8BIT_INTENSITY <- 255L

# ---- Visualization ----
# SF Pictometry 2024 aerial tile URL (XYZ pattern)
PICTOMETRY_URL <- "https://maps.sfdpw.org/arcgis/rest/services/Pictometry/Pictometry2024/MapServer/tile/{z}/{y}/{x}"
