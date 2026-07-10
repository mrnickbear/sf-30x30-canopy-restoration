# library(lidR)
# 
# ttops <- locate_trees(nlas, lmf(ws = TREE_DETECTION_WS)) %>% st_set_crs(cs13_m)
# seg <- segment_trees(las = nlas, algorithm = li2012())
# 
# metrics <- crown_metrics(las = seg, func = .stdtreemetrics)
# st_crs(metrics) <- cs13_m
# 
# crown_outlines <- st_as_sf(delineate_crowns(seg, attribute = "treeID"))
# st_crs(crown_outlines) <- cs13_m
# 
# #my ttops and seg don't know about each other's IDs
# #my crown metrics WAS based on seg, so it should match
# 
# # 3. Plot the cloud using the existing treeID attribute
# x <- plot(seg, color = "treeID", pal = pc_palette)
# 
# # 4. Add the enlarged treetops using the exact same base color vector
# add_treetops3d(x, ttops, col = tree_colors, size = 10, point_antialias = TRUE)c
# 
# 
# 
# library(mapview)
# mapview(st_zm(ttops), zcol = "treeID", legend = TRUE, alpha.regions = 0.5, layer.name = "Tree Tops") +
#   mapview(crown_outlines, color = "blue", alpha = 0.2, layer.name = "Crown Outlines")
# 



# Method 1: Pass Treetops to the Segmentation Function (Recommended)
# Algorithms like dalponte2016() or silva2016() require an initial tree-detection layer. This forces a 1:1 match across your point cloud, treetops, and crown outlines.
# 
# Here is how you update your workflow:
  
# library(lidR)
# library(sf)
# 
# #Variable window size - larger window for taller tree
# f <- function(x) {x * 0.1 + 3}
# 
# 
# # 1. Detect your treetops first
# ttops <- locate_trees(nlas, lmf(f)) %>% st_set_crs(cs13_m)
# 
# # 2. Segment using an algorithm that accepts those treetops (e.g., Dalponte 2016)
# # This forces the point cloud to use the exact IDs from 'ttops'
# seg <- segment_trees(las = nlas, algorithm = dalponte2016(chm = nlas, ttops = ttops))
# 
# # 3. Delineate crowns (IDs will match perfectly now)
# crown_outlines <- delineate_crowns(seg, attribute = "treeID") %>% st_set_crs(cs13_m)
# 
# # 4. Calculate metrics
# metrics <- crown_metrics(las = seg, func = .stdtreemetrics) %>% st_set_crs(cs13_m)


# Method 2: Generate Treetops After Segmentation (For li2012)
# If you want to stick with the li2012() algorithm, you cannot pass it ttops. 
# Instead, you have to extract the highest point of each segment after the algorithm 
# has run to ensure the IDs align.You can do this cleanly by computing your metrics 
# first (since .stdtreemetrics calculates the maximum $Z$ coordinate and its spatial 
# location per tree), and converting those metrics into your new, perfectly-matched ttops layer:

#I want to stick with Li, since its fast, and focused on dominant trees not understory

library(lidR)
library(sf)
library(mapview)

# 1. Segment using your preferred algorithm
seg <- segment_trees(las = nlas, algorithm = li2012(dt1 = 1.2, dt2 = 1.5, R = 10, speed_up = 15))

# 2. Calculate metrics (this automatically groups by the generated treeID)
metrics <- crown_metrics(las = seg, func = .stdtreemetrics) %>% st_set_crs(cs13_m)

# 3. Delineate crowns
crown_outlines <- delineate_crowns(seg, attribute = "treeID")

# 4. Generate treetops FROM the metrics
# Since 'metrics' is already an sf spatial object representing the center/highest point
# of each tree segment, it can function directly as your matched 'ttops' layer!
# ttops <- metrics
  
mapview(st_zm(metrics), zcol = "treeID", legend = TRUE, alpha.regions = 0.5, layer.name = "Tree Tops") +
mapview(crown_outlines, color = "blue", alpha = 0.2, layer.name = "Crown Outlines")

