# segment2.r
# tree segmentation

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
library(terra) #Does lidrtree use Stars library?  Maybe, but it doesn't do much raster processing.

getwd()

# Read in one LiDAR file
# las <- readLAS("tilecls/04650240.laz",  filter = "-set_withheld_flag 0", select = "xyzc") # load XYZ and classification, only 

#Turn off after running once
# Read in all files in the folder
ctg <- readLAScatalog("tilecls/") #tested select here, didn't make a difference.  Use opt_filter(ctg) = "-keep_class 2"


# las <- clip_rectangle(ctg, 46600, 23500, 48000, 24500) #For all 5 LH area tiles, clip without removing much area, to convert to LAS.  Must be a better way?
# writeLAS(las, "LH_area.las", index = FALSE)
# las <- readLAS("LH_area.las", select = "xyzc")

# las <- clip_rectangle(ctg, 46700, 23900, 47650, 24300) #For DLT, ravine and knob areas only, to check for tallest tree, 5 full tiles took too long
# writeLAS(las, "LH_north.las", index = FALSE)
# las <- readLAS("LH_north.las", select = "xyzc") 


# # las <- clip_circle(ctg, x = 47150, y = 24000, radius = 50) #Northern tip of Dan's Lost Trail
# las <- clip_circle(ctg, x = 47100, y = 24000, radius = 150) #expanded to include the old driveway and more tree species, and edge between 3 tiles
# writeLAS(las, "DLT.las", index = FALSE)
# # Load only the test area
# # las <- readLAS("DLT.las")  # 240 MB without select
las <- readLAS("DLT.las", select = "xyzc")  # 130 MB by selecting only XYZ and classification


# DLT 150 radius:
# contains Silver Acacia, Black Acacia, Blue Gum, Redwood, teasel(maybe cut off.  Species?), coyote brush, blackberry,
# Hillside with overall X% slope
# Benched singletrack trails are visible
# Revised the area to include road bed, picnic area Acacia, mention the habitat restoration
# Now power lines, curb and gutter are visible along LH Blvd
# 2 pine snages and maybe some of the lines with dead branches are included!  Snags are tall, without much area on top.
# Classes 1-Unclassified, 2-ground, 7-low points (noise)
# 



# las_check(las) # more thorough validation than whats already done by readLAS 

col <- height.colors(50)
col1 <- pastel.colors(900)

# # Generate CHM
# chm <- rasterize_canopy(las = las, res = 0.5, algorithm = p2r(0.15))
# plot(chm, col = col)
# # See chapter 7, first paragraph, the input point cloud must be height normalized,
# # otherwise the output will be canopy elevation as shown here instead of height.
# # https://r-lidar.github.io/lidRbook/dsm.html

#Starting from here to line 126, LH_area never finished on NB's laptop.  The computer seemed to have crashed and restarted overnight.
#Starting from here to line 126, LH_north took at least an hour on NB's laptop, but finished.


nlas <- normalize_height(las, knnidw())
# https://r-lidar.github.io/lidRbook/normalization.html

chm <- rasterize_canopy(las = nlas, res = 0.5, algorithm = p2r(0.15))
plot(chm, col = col)

#Chapter 8
ttops <- locate_trees(nlas, lmf(ws = 10))

plot(chm, col = height.colors(50))
plot(sf::st_geometry(ttops), add = TRUE, pch = 3)

# # Tree detection results can also be visualized in 3D!  (Turn off for large areas)
#   
#   x <- plot(nlas, bg = "white", size = 4)
# add_treetops3d(x, ttops)

#8.2
algo <- dalponte2016(chm, ttops)
seg <- segment_trees(nlas, algo) # segment point cloud #taking 4+ hours for LH_north  #Rename this so the original isn't overwritten?
# plot(las, bg = "white", size = 4, color = "treeID") # visualize trees (Turn off for large areas)


crowns <- crown_metrics(seg, func = .stdtreemetrics, geom = "concave")
plot(crowns["convhull_area"], main = "Crown area (concave hull)")
head(crowns)

plot(crowns["Z"], main = "Height")
head(crowns)

x <- plot(seg, bg = "white", size = 2, color = "treeID")
add_treetops3d(x, ttops)

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