# GitHub Copilot Repository Instructions

## Project Context
- This is a spatial data processing repository for an urban canopy restoration project.
- The project structure uses a strict data layout:
  - `data/raw_point_clouds/` for point cloud data (.las, .laz)
  - `data/vector/` for vector files (.kml, .kmz, .json, .geojson)
  - `data/terrain/` for terrain models (.tif)

## Coding Standards & Packages
- Preferred spatial packages: `sf`, `stars`
- Avoid absolute paths; always write relative file paths starting from the project root.

## Response Style
- Provide clean, production-ready R code blocks.
- Keep explanations brief and technical.