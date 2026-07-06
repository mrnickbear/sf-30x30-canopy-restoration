# segment2.r
# tree segmentation
# v3 
# v4 - remove old junk
# v4 - completed outlines of metrics, with snags circled.  Plot this on aerial photo for entire site.
# filter out ground, low vegetation points.  Speed up segmentation?  DLT_040 takes about 2m using li2012
# v4min - take out old junk, show heights with labels
# shinyapps.io - add basic shiny app.  
#
#
# for CR 16b, reload the connection each 15m instead of a query?
# Then need a shareable email/password instead of mine.

# To do: 
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

cs13_m <- 7131
cs13_f <- 7132


# Load packages
library(lidR)
library(sf)
library(terra) #Does lidrtree use Stars library?  Maybe, but it doesn't do much raster processing.'
# library(mapview)
library(scales)
library(tmap)
library(shiny)

setwd("c:\\tree")


# writeLAS(seg_snags, "LHH_aa_z3segssnags.las", index = FALSE)
seg_snags <- readALSLAS("LHH_aa_z3segssnags.las", filter = "-drop_z_below 10") #assigns type = airborne

metrics <- crown_metrics(las = seg_snags, func = .stdtreemetrics)  #func = ~list(n = length(Z)))


# # Filter and plot snag points only
# 0: Live Tree—Points identified as belonging to a live tree.
# 1: General Snag—A broad classification for snag points that do not fit into the more specific categories.
# 2: Small Snag—Snags that are isolated and have lower point densities.
# 3: Live Crown Edge Snag—Snags located directly next to or intermixed with the crowns of live trees.
# 4: High Canopy Cover Snag—Snags that stick up above the live canopy in areas of dense tree cover. 
snags <- filter_poi(seg_snags, snagCls > 0)
# plot(snags, color="snagCls", pal = rainbow(5)[-1])


# Calculate the tree crown polygons (using convex hulls)
crown_outlines <- st_as_sf(delineate_crowns(seg_snags, attribute = "treeID"))
st_crs(crown_outlines) <- cs13_m

# # View the results (optional)
# plot(chm)
# plot(crown_outlines, add = TRUE)
# plot(metrics, add = TRUE)

snag_outlines <- st_as_sf(delineate_crowns(snags, attribute = "treeID"))
st_crs(snag_outlines) <- cs13_m
st_crs(metrics) <- cs13_m

#GB 10/6/2025 - adjusting zoom from 10/5 - works for higher resolution!!
tmap_mode("view") 
pictometry_url <- "https://maps.sfdpw.org/arcgis/rest/services/Pictometry/Pictometry2024/MapServer/tile/{z}/{y}/{x}"

# 3. Create the interactive map
tmap_sf_aerial <- tm_shape(crown_outlines) +
  # # Add the custom Esri aerial layer as the basemap
  # tm_basemap(server = pictometry_url, 
  #            group = "SF Pictometry 2024") +
  # Add a simple vector layer (country borders) on top for context
  tm_borders(border.col = "grey", fill = NA, lwd = 0.5, alpha = 0) +
  tm_shape(snag_outlines)+
  tm_borders(border.col = "red", lwd = 2, alpha = 0)+
  tm_shape(metrics)+
  tm_dots(col = "Z", # Color points by this attribute
          palette = "viridis",      # Choose a color palette (e.g., "viridis", "Reds", "Blues")
          title = "Value")         # Title for the legend
  # tm_text(text = "label_attribute", # Label points with this attribute
  #         size = 0.8,               # Adjust label size
  #         col = "green",            # Color of the label text
  #         yoff = 0.5) +             # Offset the label vertically to avoid overlapping with the dot
  # tm_layout(main.title = "Trees Colored and Labeled by Height(m)") # Main map
  # 
# Display the map (it will open in your R Viewer pane or browser)
# tmap_leaflet(tmap_sf_aerial) |> 
#   leaflet::addTiles(
#     urlTemplate = pictometry_url,
#     options = leaflet::tileOptions(
#       # The maximum level of zoom the user is allowed to navigate to
#       maxZoom = 22,
#       
#       # The maximum zoom level for which we have original, non-stretched tiles
#       maxNativeZoom = 22
#     )
#   )


# Define UI for application
ui <- fluidPage(
  titlePanel("My Interactive tmap"),
  
  # Output the tmap plot
  mainPanel(
    tmapOutput("my_tmap")
  )
)

# Define server logic
server <- function(input, output) {
  # Load your spatial data
  # Example: use the built-in `World` dataset from the tmap package
  # data("World")
  
  # Create the tmap object reactively
  output$my_tmap <- renderTmap({

        tmap_sf_aerial+
        tm_basemap(server = pictometry_url, 
                  group = "SF Pictometry 2024",
                  # maxzoom = 22,
                  max.native.zoom = 22)+
        tm_view(lat = 37.7749, lon = -122.4194, zoom = 14)
  })
}

# Run the application
shinyApp(ui = ui, server = server)

#/GB




# 
# #Example
# # Create the tmap plot
# tm_shape(my_sf_points) +
#   tm_dots(col = "value_to_color_by", # Color points by this attribute
#           palette = "viridis",      # Choose a color palette (e.g., "viridis", "Reds", "Blues")
#           title = "Value") +        # Title for the legend
#   tm_text(text = "label_attribute", # Label points with this attribute
#           size = 0.8,               # Adjust label size
#           col = "black",            # Color of the label text
#           yoff = 0.5) +             # Offset the label vertically to avoid overlapping with the dot
#   tm_layout(main.title = "Points Colored and Labeled by Attributes") # Main map