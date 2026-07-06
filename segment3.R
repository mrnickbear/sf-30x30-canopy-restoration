# segment2.r
# tree segmentation
# v3 
# To do: filter out ground, low vegetation points.  Speed up segmentation?  DLT_040 takes about 2m
#DLT_040 area = 5000 sq m
#Full LHH analysis area = 134000 sq m, or 27x larger.

# source of laz files
# https://gis.sf.gov/dload/sf3d.xyz/USGS_CA_SanFrancisco_1_B23/point_cloud/tilecls/ #OK to share??
# also available from USGS
# https://apps.nationalmap.gov/downloader/

# tile map
# https://www.google.com/maps/d/u/2/edit?mid=1Sivnn2Hjcy9nso-3Zh0yZTbrnRceLEI&usp=sharing

#Individual Tree Detection & Segmentation
# https://tgoodbody.github.io/lidRtutorial/06_its.html
# https://r-lidar.github.io/lidRbook/  Canada

#related?
#https://github.com/bcgov/gis-pantry/blob/master/docs/getting-started-with-QGIS/doc/R-and-QGIS.md

#parallel library??  France
# https://lidar.pages-forge.inrae.fr/lidaRtRee/index.html


#Question: Does LHH have the tallest tree in SF?
# https://hoodline.com/2017/04/san-francisco-s-nameless-giant-in-search-of-the-city-s-tallest-tree/
# Stern Grove 66m
# https://cosam.calpoly.edu/news/cal-poly-ca-big-tree-tour
# Petrolia 43m (largest, not tallest)

#For fun: show the ballpark bird poop example

#Plants that might be identifiable:

#Invasive Species
#Black Acacia         https://www.cal-ipc.org/plants/profile/acacia-melanoxylon-profile/
#Silver Wattle        https://www.cal-ipc.org/plants/profile/acacia-dealbata-profile/
#Blue Gum             https://www.cal-ipc.org/plants/profile/eucalyptus-globulus-profile/
#Himalayan Blackberry https://www.cal-ipc.org/plants/profile/rubus-armeniacus-profile/
#Tree covered in Ivy  No trunk visible, cylindrical shape.


#Native Species
#Coyote brush         https://calscape.org/Baccharis-pilularis-(Coyote-Bush)
#Coast live oak       https://calscape.org/Quercus-agrifolia-(Coast-Live-Oak)   (there may not be any large enough yet)
#Monterey pine        https://calscape.org/Pinus-radiata-(Monterey-Pine)
#Redwood




# Clear environment
rm(list = ls(globalenv())) #Add this to my other scripts??

# Load packages
library(lidR)
library(sf)
library(terra) #Does lidrtree use Stars library?  Maybe, but it doesn't do much raster processing.'
library(mapview)
library(scales)

# getwd()

# Read in one LiDAR file
# las <- readLAS("tilecls/04650240.laz",  filter = "-set_withheld_flag 0", select = "xyzc") # load XYZ and classification, only 

#Turn off after running once
# Read in all files in the folder
ctg <- readLAScatalog("tilecls/") #tested select here, didn't make a difference.  Use opt_filter(ctg) = "-keep_class 2"

aa <- st_cast(st_read("analysisarea.kml"), "POLYGON")
aa <- st_cast(st_read("updatedAA.kml"), "POLYGON")
aa$area <- st_area(aa)
  

citylands <- st_cast(st_read("City_Lands_20250928.geojson"), "POLYGON")
clarendon_ps <- citylands[citylands$address == "201 OLYMPIA WAY" & !is.na(citylands$address),]
# st_write(clarendon_ps, "clarendon_ps.kml")
# 
# 
# mapviewOptions(fgb = FALSE)
# mapview(aa) + mapview(clarendon_ps)
# st_area(aa)

# las <- clip_rectangle(ctg, 46600, 23500, 48000, 24500) #For all 5 LH area tiles, clip without removing much area, to convert to LAS.  Must be a better way?
# writeLAS(las, "LH_area.las", index = FALSE)
# las <- readLAS("LH_area.las", select = "xyzc")

# las <- clip_rectangle(ctg, 46700, 23900, 47650, 24300) #For DLT, ravine and knob areas only, to check for tallest tree, 5 full tiles took too long
# writeLAS(las, "LH_north.las", index = FALSE)
# las <- readLAS("LH_north.las", select = "xyzc") 


# # las <- clip_circle(ctg, x = 47150, y = 24000, radius = 50) #Northern tip of Dan's Lost Trail
# las <- clip_circle(ctg, x = 47100, y = 24000, radius = 150) #expanded to include the old driveway and more tree species, and edge between 3 tiles

# las <- clip_circle(ctg, x = 47200, y = 23900, radius = 70) #Includes pine snags, big eucs, ivy trees, trees with dead ivy?, acacia
# las <- clip_circle(ctg, x = 47200, y = 23900, radius = 40) #Includes pine snags, big eucs, ivy trees, trees with dead ivy?, acacia

# writeLAS(las, "DLT_150.las", index = FALSE)
# writeLAS(las, "DLT_070.las", index = FALSE)
# writeLAS(las, "DLT_040.las", index = FALSE)


# # Load only the test area
# # las <- readLAS("DLT.las")  # 240 MB without select
# las <- readLAS("DLT.las", select = "xyzc")  # 130 MB by selecting only XYZ and classification
# las <- readLAS("DLT_150.las", select = "xyzc")  # xxx MB by selecting only XYZ and classification
# las <- readLAS("DLT_040.las", select = "xyzc")  # xxx MB by selecting only XYZ and classification



# DLT 150 radius: (before shifting south 200 ft - keep going if no pine, want the snags)
# contains Silver Acacia, Black Acacia, Blue Gum, Redwood, teasel(maybe cut off.  Species?), coyote brush, blackberry,
# Hillside with overall X% slope
# Benched singletrack trails are visible
# Revised the area to include road bed, picnic area Acacia, mention the habitat restoration
# Now power lines, curb and gutter are visible along LH Blvd
# 2 pine snages and maybe some of the lines with dead branches are included!  Snags are tall, without much area on top.
# Classes 1-Unclassified, 2-ground, 7-low points (noise)
# 

# las <- readLAS("DLT_040.las", select = "xyzi", filter="-keep_first -keep_single") # Wing also included -keep_single
las <- readALSLAS("DLT_040.las", select = "xyzic") #assigns type = airborne


# las_check(las) # more thorough validation than whats already done by readLAS 

col <- height.colors(50)
col1 <- pastel.colors(900)

# Generate CHM
chm <- rasterize_canopy(las = las, res = 0.5, algorithm = p2r(0.15))
plot(chm, col = col)
# See chapter 7, first paragraph, the input point cloud must be height normalized,
# otherwise the output will be canopy elevation as shown here instead of height.
# https://r-lidar.github.io/lidRbook/dsm.html

#Starting from here to line 126, LH_area never finished on NB's laptop.  The computer seemed to have crashed and restarted overnight.
#Starting from here to line 126, LH_north took at least an hour on NB's laptop, but finished.


# #Raster approach works, but how to turn back on concavity?
# #Should be using the available DEM here?  Instead of making its own inside this fn?
nlas <- normalize_height(las, knnidw())
# # https://r-lidar.github.io/lidRbook/normalization.html
# 
chm <- rasterize_canopy(las = nlas, res = 0.5, algorithm = p2r(0.15))
plot(chm, col = col)
# 
# #Chapter 8
ttops <- locate_trees(nlas, lmf(ws = 10))

plot(chm, col = height.colors(50))
plot(sf::st_geometry(ttops), add = TRUE, pch = 3)

# # # Tree detection results can also be visualized in 3D!  (Turn off for large areas)
# #   
# #   x <- plot(nlas, bg = "white", size = 4)
# # add_treetops3d(x, ttops)
# 
# #8.2
algo <- dalponte2016(chm, ttops)
seg <- segment_trees(nlas, algo) # segment point cloud #taking 4+ hours for LH_north  #Rename this so the original isn't overwritten?
# plot(las, bg = "white", size = 4, color = "treeID") # visualize trees (Turn off for large areas)


crowns <- crown_metrics(seg, func = .stdtreemetrics) #, geom = "concave")
# plot(crowns["convhull_area"], main = "Crown area")# (concave hull)")
head(crowns)
# 
# # plot(crowns["Z"], main = "Height")
# head(crowns)
# 
# x <- plot(seg, bg = "white", size = 2, color = "treeID")
# add_treetops3d(x, ttops)


# # https://tgoodbody.github.io/lidRtutorial/06_its.html
# # Detect trees
# ttops <- locate_trees(las = las, algorithm = lmf(ws = 3, hmin = 5))

# Visualize
# x <- plot(las)
# add_treetops3d(x = x, ttops = ttops, radius = 0.5)

# # Segment using li (slow - few minutes for DLT_040)
seg <- segment_trees(las = nlas, algorithm = li2012())

# plot(seg, color = "treeID")
# From tutorial: This algorithm does not seem pertinent for this dataset.


metrics <- crown_metrics(las = seg, func = .stdtreemetrics)  #func = ~list(n = length(Z)))
metrics


#Rows (Height Strata): The three rows represent the lower, middle, and upper thirds of the tree's height.
#Columns (Conditions): The four columns represent the following thresholds, as derived from the original Wing et al. (2015) paper:
# Column 1: Bole-point ratio (BPR) threshold for the first iteration.
# Column 2: Branch-point ratio (BrPR) threshold for the first iteration.
# Column 3: BPR threshold for the second iteration (using a smaller window size).
# Column 4: BrPR threshold for the second iteration


# plot(las)
# summary(seg$Intensity) #confirmed my intensities are 16-bit
seg@data[, Intensity := as.integer(Intensity/(2^16-1)*255L)] #rescale intensity to 8-bit for Wing's algorithm



# Sample from page 119 https://cran.r-project.org/web/packages/lidR/lidR.pdf
bbpr_thresholds <- matrix(
  c(0.80, 0.80, 0.70, 0.85, 
    0.85, 0.60, 0.80, 0.80, 
    0.60, 0.90, 0.90, 0.55
  ),
  nrow =3, ncol = 4
)

#no 0's in my 2023 lidar data - decrease thresholds? (first, rescaled intensity)
bbpr_thresholds <- matrix(
  c(0.70, 0.70, 0.60, 0.75,
    0.75, 0.50, 0.70, 0.70,
    0.50, 0.80, 0.80, 0.45
  ),
  nrow =3, ncol = 4
)

# Run snag classification and assign classes to each point
seg_snags <- segment_snags(seg, wing2015(neigh_radii = c(1.5, 1, 2), BBPRthrsh_mat = bbpr_thresholds))
# Plot it all, tree and snag points...
plot(seg_snags, color="snagCls", pal = rainbow(5))
# # Filter and plot snag points only
# 0: Live Tree—Points identified as belonging to a live tree.
# 1: General Snag—A broad classification for snag points that do not fit into the more specific categories.
# 2: Small Snag—Snags that are isolated and have lower point densities.
# 3: Live Crown Edge Snag—Snags located directly next to or intermixed with the crowns of live trees.
# 4: High Canopy Cover Snag—Snags that stick up above the live canopy in areas of dense tree cover. 
snags <- filter_poi(seg_snags, snagCls > 0)
plot(snags, color="snagCls", pal = rainbow(5)[-1])



#BElow here doesn't  work yet - goal: show all points with snag points highlighted.
seg_snags@data[, snagCls := ifelse(snagCls == 0, 0.2, ifelse(snagCls > 0, 1.0, 1.0))] #rescale intensity to 8-bit for Wing's algorithm


seg_snags@data[, combined_color := alpha(
  treeID,
  alpha = snagCls
)]

plot(seg_snags, color = "combined_color")



summary(seg_snags$snagCls) #

plot(seg_snags, color = "treeID", alpha = "snagCls")


#out of order?
#Does segment_trees() Filter out ground points?  What about low height trees?  
#Add both to a pre filter before segment and segment_snag
#check result at hillside above meadow



#Better to rasterize then plot so it shows in the Viewer window?  To avoid generating many big 3D viewer windows.



# #GB suggested the commented out lines that weren't in the example from https://cran.r-project.org/web/packages/lidR/lidR.pdf 
# snags <- segment_snags(las,
#                        wing2015( neigh_radii = c(1.5, 1, 2),
#                         # low_int_thrsh = 50,
#                         # uppr_int_thrsh = 170,
#                         # pt_den_req = 3,
#                         BBPRthrsh_mat = bbpr_thresholds
#                       )#,
#                       #attribute = "snagCls"
#                     )
# 
# plot(snags)


#find snags
#Powerlines and other tree segmentation algorithms - later - https://github.com/Jean-Romain/lidRplugins




# #investigate the outlier near the brick inlet
# #there is noise above the trees and below the ground
# #lake reflection??
# brick_nlas <- clip_circle(las, x = 47200, y = 24200, radius = 100)
# 
# plot(brick_nlas, bg = "white", size = 2, color = "treeID")
# plot(brick_nlas, bg = "white", size = 2, color = "Z")
# 
# #investigate the ravine area that has the tallest trees
# rnlas <- clip_rectangle(nlas, 47150, 24050, 47600, 24220)
# # writeLAS(rnlas, "rnlas.las", index = TRUE)
# rchm <- rasterize_canopy(las = rnlas, res = 0.5, algorithm = p2r(0.15))
# plot(rchm, col = col)

# #Chapter 8
# rttops <- locate_trees(nlas, lmf(ws = 5))
# ralgo <- dalponte2016(chm, rttops)
# rseg <- segment_trees(nlas, ralgo)
# 
# 
# rcrowns <- crown_metrics(rseg, func = .stdtreemetrics, geom = "convex")
# plot(rcrowns["convhull_area"], main = "Crown area (convex hull)")
# head(rcrowns)
# 
# x <- plot(rseg, bg = "white", size = 2, color = "treeID")
# add_treetops3d(x, rttops)