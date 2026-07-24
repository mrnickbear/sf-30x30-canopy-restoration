# run_pipeline.R
# Master pipeline runner.
#
# Set the flags below to control which steps execute.
# Segmentation (step 2) is automatically skipped when the output LAS file
# already exists; set FORCE_SEGMENT = TRUE to override and re-run it.
#
# Pipeline overview:
#
#   Step 1  01_load_data.R  – Load LiDAR catalog, define AOI, clip to `las`.
#   Step 2  02_segment.R    – Normalize heights, segment trees, classify snags,
#                             save to OUTPUT_LAS_PATH.  Slow – skip when done.
#   Step 3  03_visualize.R  – Load saved results, compute metrics, show map.
#   Step 4  04_pointcloud_web_prep.R – Export buffered per-tree LAZ files for
#                                      trees taller than 30 m.
#
# Usage:
#   Open RStudio, set the working directory to the project root, then:
#     source("run_pipeline.R")
#   Or run individual steps:
#     source("01_load_data.R")
#     source("02_segment.R")
#     source("03_visualize.R")
#     source("04_pointcloud_web_prep.R")
#
#   To run test server:
#   1. Start the server and save its handle
#   my_server <- servr::httd(port = 8080)
#   Then browse to http://localhost:8080/
#   # 2. When you are done, shut down only that specific server
#   servr::daemon_stop(my_server)


# ---- Configuration ----
# Clear the global environment, then load shared settings.
rm(list = ls())
source("config.R")

# ---- Step flags ----
# Validate OUTPUT_LAS_PATH before using it in file.exists().
if (!nzchar(OUTPUT_LAS_PATH)) {
  stop("OUTPUT_LAS_PATH in config.R is empty. Please set a valid file path.")
}

# FORCE_SEGMENT = FALSE: skip step 2 when OUTPUT_LAS_PATH already exists.
# FORCE_SEGMENT = TRUE:  always re-run segmentation (overwrites the saved file).
FORCE_SEGMENT  <- TRUE

RUN_LOAD_DATA  <- TRUE
RUN_SEGMENT    <- FORCE_SEGMENT || !file.exists(OUTPUT_LAS_PATH)

RUN_VISUALIZE  <- TRUE #consolidated with step 2
RUN_WEB_PREP   <- TRUE #consolidated with step 2

# ---- Step 1: Load data ----
if (RUN_LOAD_DATA) {
  message("\n=== Step 1: Load data ===")
  source("01_load_data.R")
}

# ---- Step 2: Segment ----
if (RUN_SEGMENT) {
  if (!exists("las")) {
    message("'las' not found; running Step 1 first.")
    source("01_load_data.R")
  }
  message("\n=== Step 2: Segment ===")
  source("02_segment.R")
} else {
  message("\nSkipping Step 2 (segmentation already saved at: ", OUTPUT_LAS_PATH, ")")
  message("Set FORCE_SEGMENT <- TRUE in run_pipeline.R to re-run.")
}

# ---- Step 3: Visualize ----
if (RUN_VISUALIZE) {
  message("\n=== Step 3: Visualize ===")
  source("03_visualize.R")
}

# ---- Step 4: Web point cloud prep ----
if (RUN_WEB_PREP) {
  message("\n=== Step 4: Web point cloud prep ===")
  source("04_pointcloud_web_prep.R")
}

message("\nPipeline complete.")
